import 'dart:async';

import '../adapters/sync_storage.dart';
import '../adapters/sync_transport.dart';
import '../entities/sync_entity.dart';
import '../events/sync_event.dart';
import '../models/exceptions.dart';
import '../models/sync_error.dart';
import '../models/sync_id_mapping.dart';
import '../models/sync_request.dart';
import '../models/sync_response.dart';
import '../queue/operation.dart';
import '../queue/operation_status.dart';
import '../queue/operation_type.dart';
import '../scheduler/retry_policy.dart';
import '../utils/clock.dart';
import 'delivery_outcome.dart';
import 'response_classifier.dart';

/// Builds the remote request that delivers an operation.
///
/// The engine always overrides the request's account, idempotency key and
/// operation ID with the operation's own values, so a builder cannot
/// accidentally break deduplication or account isolation.
typedef SyncRequestBuilder = FutureOr<SyncRequest> Function(
  SyncOperation operation,
);

/// What happened to one operation during execution.
enum ExecutionResult {
  /// Another worker claimed the operation first; nothing was done.
  notClaimed,

  /// The server acknowledged the operation.
  acknowledged,

  /// A transient failure; the operation is scheduled for retry.
  retryScheduled,

  /// The operation was permanently rejected.
  rejected,

  /// The operation hit a version conflict.
  conflict,

  /// The server requires re-authentication; the operation is pending again.
  authenticationRequired,

  /// The lease was lost before the result could be recorded.
  leaseLost,
}

/// Delivers a single operation: lease → build → mark sending → send →
/// classify → persist → emit.
///
/// Internal to the engine. Exceptions from the request builder and transport
/// are classified; `Error`s (programming bugs) propagate, leaving the
/// operation leased until its lease expires and recovery re-queues it.
final class OperationExecutor {
  /// Creates an executor.
  OperationExecutor({
    required SyncStorage storage,
    required SyncTransport transport,
    required SyncRequestBuilder requestBuilder,
    required RetryPolicy retryPolicy,
    required SyncResponseClassifier classifier,
    required Clock clock,
    required String workerId,
    required Duration leaseDuration,
    required void Function(SyncEvent event) emit,
    SyncEntityRegistry? entities,
  })  : _entities = entities,
        _storage = storage,
        _transport = transport,
        _requestBuilder = requestBuilder,
        _retryPolicy = retryPolicy,
        _classifier = classifier,
        _clock = clock,
        _workerId = workerId,
        _leaseDuration = leaseDuration,
        _emit = emit;

  final SyncStorage _storage;
  final SyncTransport _transport;
  final SyncRequestBuilder _requestBuilder;
  final RetryPolicy _retryPolicy;
  final SyncResponseClassifier _classifier;
  final Clock _clock;
  final String _workerId;
  final Duration _leaseDuration;
  final void Function(SyncEvent event) _emit;
  final SyncEntityRegistry? _entities;

  /// Executes the operation with [operationId] if it can still be claimed.
  Future<ExecutionResult> execute(String operationId) async {
    final claimedAt = _clock.now();
    final leased = await _storage.acquireLease(
      operationId: operationId,
      workerId: _workerId,
      now: claimedAt,
      expiresAt: claimedAt.add(_leaseDuration),
    );
    if (leased == null) return ExecutionResult.notClaimed;

    final SyncRequest request;
    try {
      request = (await _requestBuilder(leased)).copyWith(
        accountId: leased.accountId,
        idempotencyKey: leased.idempotencyKey,
        operationId: leased.id,
      );
    } on Exception {
      final now = _clock.now();
      final rejected = leased
          .transitionTo(SyncOperationStatus.sending, at: now)
          .transitionTo(SyncOperationStatus.rejected, at: now)
          .copyWith(
            lastError: SyncError(
              category: SyncErrorCategory.serialization,
              message: 'The request for this operation could not be built.',
              isRetryable: false,
              operationId: leased.id,
              occurredAt: now,
            ),
          );
      return _persist(
        rejected,
        ExecutionResult.rejected,
        (stored) => OperationRejected(operation: stored, at: now),
      );
    }

    final sendingAt = _clock.now();
    final SyncOperation sending;
    try {
      sending = await _storage.updateOperation(
        leased
            .transitionTo(SyncOperationStatus.sending, at: sendingAt)
            .copyWith(attempts: leased.attempts + 1, lastAttemptAt: sendingAt),
      );
    } on StaleOperationException {
      return _leaseLost(leased.id);
    } on OperationNotFoundException {
      return _leaseLost(leased.id);
    }

    DeliveryOutcome outcome;
    try {
      final response = await _transport.send(request);
      outcome = _classifier.classifyResponse(
        response,
        operationId: sending.id,
        now: _clock.now(),
      );
    } on SyncTransportException catch (exception) {
      outcome = _classifier.classifyTransportException(
        exception,
        operationId: sending.id,
        now: _clock.now(),
      );
    } on Exception {
      outcome = DeliveryRetryable(
        SyncError(
          category: SyncErrorCategory.unknown,
          message: 'The transport failed unexpectedly.',
          isRetryable: true,
          operationId: sending.id,
          occurredAt: _clock.now(),
        ),
      );
    }

    return _apply(sending, outcome);
  }

  Future<ExecutionResult> _apply(
    SyncOperation sending,
    DeliveryOutcome outcome,
  ) {
    final now = _clock.now();
    switch (outcome) {
      case DeliverySucceeded(:final response):
        final acknowledged = sending
            .transitionTo(SyncOperationStatus.acknowledged, at: now)
            .copyWith(clearLastError: true, clearNextAttemptAt: true);
        SyncEvent ackEvent(SyncOperation stored) => OperationAcknowledged(
              operation: stored,
              response: response,
              at: now,
            );
        final mapping = _idMappingFor(sending, response, now);
        if (mapping == null) {
          return _persist(acknowledged, ExecutionResult.acknowledged, ackEvent);
        }
        return _persistWithMapping(acknowledged, mapping, ackEvent);

      case DeliveryRetryable(:final error, :final retryAfter):
        final delay = _retryPolicy.delayFor(
          attempts: sending.attempts,
          error: error,
          retryAfter: retryAfter,
        );
        if (delay == null) {
          return _reject(sending, _exhausted(error), now);
        }
        return _persist(
          sending
              .transitionTo(SyncOperationStatus.retryScheduled, at: now)
              .copyWith(lastError: error, nextAttemptAt: now.add(delay)),
          ExecutionResult.retryScheduled,
          (stored) => OperationRetryScheduled(operation: stored, at: now),
        );

      case DeliveryUnauthenticated(:final error):
        return _persist(
          sending
              .transitionTo(SyncOperationStatus.pending, at: now)
              .copyWith(lastError: error, clearNextAttemptAt: true),
          ExecutionResult.authenticationRequired,
          (stored) => AuthenticationRequired(
            accountId: stored.accountId,
            operation: stored,
            at: now,
          ),
        );

      case DeliveryRejected(:final error):
        return _reject(sending, error, now);

      case DeliveryConflicted(:final error, :final response):
        return _persist(
          sending
              .transitionTo(SyncOperationStatus.conflict, at: now)
              .copyWith(lastError: error, clearNextAttemptAt: true),
          ExecutionResult.conflict,
          (stored) => OperationConflicted(
            operation: stored,
            response: response,
            at: now,
          ),
        );
    }
  }

  Future<ExecutionResult> _reject(
    SyncOperation sending,
    SyncError error,
    DateTime now,
  ) =>
      _persist(
        sending
            .transitionTo(SyncOperationStatus.rejected, at: now)
            .copyWith(lastError: error, clearNextAttemptAt: true),
        ExecutionResult.rejected,
        (stored) => OperationRejected(operation: stored, at: now),
      );

  // Writes the final state, then emits. A stale write means the lease expired
  // and the operation was recovered by someone else: the result is dropped and
  // the operation will be delivered again with the same idempotency key.
  Future<ExecutionResult> _persist(
    SyncOperation next,
    ExecutionResult result,
    SyncEvent Function(SyncOperation stored) event,
  ) async {
    final SyncOperation stored;
    try {
      stored = await _storage.updateOperation(next);
    } on StaleOperationException {
      return _leaseLost(next.id);
    } on OperationNotFoundException {
      return _leaseLost(next.id);
    }
    _emit(event(stored));
    return result;
  }

  // A create acknowledged with a server ID different from the local one.
  SyncIdMapping? _idMappingFor(
    SyncOperation operation,
    SyncResponse response,
    DateTime now,
  ) {
    if (operation.operationType != SyncOperationType.create) return null;
    final extract = _entities?[operation.entityName]?.serverIdFrom;
    final serverId = extract?.call(response);
    if (serverId == null ||
        serverId.isEmpty ||
        serverId == operation.entityId) {
      return null;
    }
    return SyncIdMapping(
      accountId: operation.accountId,
      entityName: operation.entityName,
      localId: operation.entityId,
      serverId: serverId,
      createdAt: now,
    );
  }

  // The acknowledgement and the ID mapping are committed together: a crash
  // can never leave an acknowledged create whose dependents would be sent to
  // the temporary ID.
  Future<ExecutionResult> _persistWithMapping(
    SyncOperation acknowledged,
    SyncIdMapping mapping,
    SyncEvent Function(SyncOperation stored) ackEvent,
  ) async {
    final SyncOperation stored;
    try {
      stored = await _storage.runInTransaction(() async {
        final result = await _storage.updateOperation(acknowledged);
        await _storage.saveIdMapping(mapping);
        return result;
      });
    } on StaleOperationException {
      return _leaseLost(acknowledged.id);
    } on OperationNotFoundException {
      return _leaseLost(acknowledged.id);
    }
    _emit(ackEvent(stored));
    _emit(
      EntityIdAssigned(
        accountId: mapping.accountId,
        entityName: mapping.entityName,
        localId: mapping.localId,
        serverId: mapping.serverId,
        at: mapping.createdAt,
      ),
    );
    return ExecutionResult.acknowledged;
  }

  ExecutionResult _leaseLost(String operationId) {
    _emit(OperationLeaseLost(operationId: operationId, at: _clock.now()));
    return ExecutionResult.leaseLost;
  }

  static SyncError _exhausted(SyncError error) => SyncError(
        category: error.category,
        message: 'Retry limit reached. Last error: ${error.message}',
        isRetryable: false,
        httpStatus: error.httpStatus,
        serverRequestId: error.serverRequestId,
        operationId: error.operationId,
        occurredAt: error.occurredAt,
      );
}
