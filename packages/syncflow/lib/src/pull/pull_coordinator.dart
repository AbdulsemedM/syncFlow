import '../adapters/sync_storage.dart';
import '../adapters/sync_transport.dart';
import '../entities/sync_entity.dart';
import '../events/sync_event.dart';
import '../executor/delivery_outcome.dart';
import '../executor/response_classifier.dart';
import '../models/exceptions.dart';
import '../models/sync_checkpoint.dart';
import '../models/sync_error.dart';
import '../models/sync_request.dart';
import '../models/sync_response.dart';
import '../utils/clock.dart';
import 'remote_change.dart';

/// Outcome of pulling one entity.
final class PullOutcome {
  /// Creates an outcome.
  const PullOutcome({
    required this.applied,
    this.error,
    this.authenticationRequired = false,
  });

  /// Number of remote changes applied.
  final int applied;

  /// The failure, if the pull stopped early.
  final SyncError? error;

  /// Whether the server requires re-authentication.
  final bool authenticationRequired;

  /// Whether the pull failed.
  bool get failed => error != null;
}

/// Pulls remote changes for one entity. Internal to the engine.
///
/// Invariants:
/// * a page and its checkpoint are committed in one storage transaction;
/// * the checkpoint never moves backwards or past unapplied changes;
/// * an expired cursor triggers at most one full resynchronization per pull.
final class PullCoordinator {
  /// Creates a coordinator.
  PullCoordinator({
    required SyncStorage storage,
    required SyncTransport transport,
    required SyncResponseClassifier classifier,
    required Clock clock,
    required void Function(SyncEvent event) emit,
    this.maxPagesPerPull = 100,
    this.timeout,
  })  : _storage = storage,
        _transport = transport,
        _classifier = classifier,
        _clock = clock,
        _emit = emit;

  final SyncStorage _storage;
  final SyncTransport _transport;
  final SyncResponseClassifier _classifier;
  final Clock _clock;
  final void Function(SyncEvent event) _emit;

  /// Upper bound on pages fetched per entity and run.
  final int maxPagesPerPull;

  /// Per-request timeout, or `null` for the transport default.
  final Duration? timeout;

  /// Pulls [entity] for [accountId] until the feed is drained, the page limit
  /// is reached, or a failure occurs.
  Future<PullOutcome> pull(String accountId, SyncEntity entity) async {
    final endpoint = entity.pull!;
    final adapter = entity.adapter!;
    var cursor = (await _storage.getCheckpoint(
      accountId: accountId,
      entityName: entity.name,
    ))
        ?.cursor;
    var applied = 0;
    var resynced = false;

    for (var page = 0; page < maxPagesPerPull; page++) {
      final SyncResponse response;
      try {
        response = await _transport.send(
          SyncRequest(
            method: SyncHttpMethod.get,
            path: endpoint.path,
            accountId: accountId,
            queryParameters: {
              if (cursor != null) endpoint.cursorParameter: cursor,
              if (endpoint.limitParameter case final limit?)
                limit: '${endpoint.pageSize}',
            },
            timeout: timeout,
          ),
        );
      } on SyncTransportException catch (exception) {
        return _failed(
          accountId,
          entity,
          applied,
          _classifier.classifyTransportException(
            exception,
            operationId: 'pull:${entity.name}',
            now: _clock.now(),
          ),
        );
      }

      if (response.statusCode == endpoint.expiredCursorStatus &&
          cursor != null &&
          !resynced) {
        _emit(
          FullResyncStarted(
            accountId: accountId,
            entityName: entity.name,
            at: _clock.now(),
          ),
        );
        await _storage.runInTransaction(adapter.prepareFullResync);
        cursor = null;
        resynced = true;
        page--;
        continue;
      }

      if (!response.isSuccessful) {
        return _failed(
          accountId,
          entity,
          applied,
          _classifier.classifyResponse(
            response,
            operationId: 'pull:${entity.name}',
            now: _clock.now(),
          ),
        );
      }

      final List<RemoteChange> changes;
      final String? nextCursor;
      final bool hasMore;
      try {
        final parsed = endpoint.parse(response, entity.name);
        nextCursor = parsed.nextCursor;
        hasMore = parsed.hasMore;
        changes = [
          for (final change in parsed.changes)
            change.withPendingLocalChanges(
              await _storage.findLatestActiveOperation(
                    accountId: accountId,
                    entityName: entity.name,
                    entityId: change.entityId,
                  ) !=
                  null,
            ),
        ];
      } on FormatException {
        return _failedWith(
          accountId,
          entity,
          applied,
          SyncErrorCategory.protocol,
          'The change feed response could not be parsed.',
        );
      }

      try {
        await _storage.runInTransaction(() async {
          if (changes.isNotEmpty) await adapter.applyRemoteChanges(changes);
          if (nextCursor != null && nextCursor != cursor) {
            await _storage.saveCheckpoint(
              SyncCheckpoint(
                accountId: accountId,
                entityName: entity.name,
                cursor: nextCursor,
                updatedAt: _clock.now(),
              ),
            );
          }
        });
      } on SyncFlowException {
        rethrow;
      } on Exception {
        return _failedWith(
          accountId,
          entity,
          applied,
          SyncErrorCategory.storage,
          'Remote changes could not be applied locally.',
        );
      }

      applied += changes.length;
      _emit(
        RemoteChangesApplied(
          accountId: accountId,
          entityName: entity.name,
          changes: changes.length,
          cursor: nextCursor ?? cursor,
          at: _clock.now(),
        ),
      );

      // Stop when drained, or when the server makes no progress.
      if (!hasMore || nextCursor == null || nextCursor == cursor) break;
      cursor = nextCursor;
    }
    return PullOutcome(applied: applied);
  }

  PullOutcome _failed(
    String accountId,
    SyncEntity entity,
    int applied,
    DeliveryOutcome outcome,
  ) {
    final error = switch (outcome) {
      DeliverySucceeded() => throw StateError('not a failure'),
      DeliveryRetryable(:final error) => error,
      DeliveryUnauthenticated(:final error) => error,
      DeliveryRejected(:final error) => error,
      DeliveryConflicted(:final error) => error,
    };
    _emit(
      PullFailed(
        accountId: accountId,
        entityName: entity.name,
        error: error,
        at: _clock.now(),
      ),
    );
    return PullOutcome(
      applied: applied,
      error: error,
      authenticationRequired: outcome is DeliveryUnauthenticated,
    );
  }

  PullOutcome _failedWith(
    String accountId,
    SyncEntity entity,
    int applied,
    SyncErrorCategory category,
    String message,
  ) {
    final error = SyncError(
      category: category,
      message: message,
      isRetryable: true,
      occurredAt: _clock.now(),
    );
    _emit(
      PullFailed(
        accountId: accountId,
        entityName: entity.name,
        error: error,
        at: _clock.now(),
      ),
    );
    return PullOutcome(applied: applied, error: error);
  }
}
