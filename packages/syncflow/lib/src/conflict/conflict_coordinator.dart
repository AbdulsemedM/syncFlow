import '../adapters/sync_storage.dart';
import '../entities/sync_entity.dart';
import '../events/sync_event.dart';
import '../models/exceptions.dart';
import '../pull/remote_change.dart';
import '../queue/operation.dart';
import '../queue/operation_status.dart';
import '../utils/clock.dart';
import 'conflict.dart';

/// Applies conflict resolutions. Internal to the engine.
final class ConflictCoordinator {
  /// Creates a coordinator.
  ConflictCoordinator({
    required SyncStorage storage,
    required Clock clock,
    required void Function(SyncEvent event) emit,
    SyncEntityRegistry? entities,
  })  : _storage = storage,
        _clock = clock,
        _emit = emit,
        _entities = entities;

  final SyncStorage _storage;
  final Clock _clock;
  final void Function(SyncEvent event) _emit;
  final SyncEntityRegistry? _entities;

  /// Runs the entity's resolver for a freshly detected conflict. Returns
  /// `true` if the conflict was settled automatically. Otherwise emits
  /// [ConflictDetected] and leaves it for manual resolution.
  Future<bool> autoResolve(String operationId) async {
    final operation = await _storage.getOperation(operationId);
    final conflict = await _storage.getConflict(operationId);
    if (operation == null ||
        conflict == null ||
        operation.status != SyncOperationStatus.conflict) {
      return false;
    }

    final resolver = _entities?[operation.entityName]?.conflictResolver;
    ConflictResolution resolution = const RequireManualResolution();
    if (resolver != null) {
      try {
        resolution = await resolver(operation, conflict);
      } on Exception {
        // A failing resolver must not lose the conflict: fall back to manual.
        resolution = const RequireManualResolution();
      }
    }

    if (resolution is RequireManualResolution) {
      _emit(
        ConflictDetected(
          operation: operation,
          conflict: conflict,
          at: _clock.now(),
        ),
      );
      return false;
    }
    try {
      await resolve(operationId, resolution);
    } on StaleOperationException {
      return false;
    }
    return true;
  }

  /// Settles the conflict of [operationId] with [resolution].
  ///
  /// The operation update, the adapter call for [UseRemote] and the removal of
  /// the conflict record happen in one storage transaction.
  Future<SyncOperation> resolve(
    String operationId,
    ConflictResolution resolution,
  ) async {
    if (resolution is RequireManualResolution) {
      throw ArgumentError.value(
        resolution,
        'resolution',
        'manual resolution cannot be applied; choose an outcome',
      );
    }
    final now = _clock.now();
    final stored = await _storage.runInTransaction(() async {
      final operation = await _storage.getOperation(operationId);
      if (operation == null) throw OperationNotFoundException(operationId);
      if (operation.status != SyncOperationStatus.conflict) {
        throw InvalidStateTransitionException(
          operationId: operationId,
          from: operation.status,
          to: resolution is UseRemote
              ? SyncOperationStatus.cancelled
              : SyncOperationStatus.pending,
        );
      }
      final conflict = await _storage.getConflict(operationId);

      final next = switch (resolution) {
        UseLocal() => _rebase(operation, conflict, now),
        MergeResolution(:final payload) =>
          _rebase(operation, conflict, now).copyWith(payload: payload),
        UseRemote() => await _keepRemote(operation, conflict, now),
        RequireManualResolution() => throw StateError('unreachable'),
      };
      final result = await _storage.updateOperation(next);
      await _storage.deleteConflict(operationId);
      return result;
    });
    _emit(ConflictResolved(operation: stored, resolution: resolution, at: now));
    return stored;
  }

  // Back to the queue on top of the server's version. Without a known
  // version the base version is dropped: the write becomes unconditional.
  static SyncOperation _rebase(
    SyncOperation operation,
    SyncConflict? conflict,
    DateTime now,
  ) {
    final remoteVersion = conflict?.remoteVersion;
    return operation
        .transitionTo(SyncOperationStatus.pending, at: now)
        .copyWith(
          baseVersion: remoteVersion,
          clearBaseVersion: remoteVersion == null,
          attempts: 0,
          clearLastError: true,
          clearNextAttemptAt: true,
        );
  }

  Future<SyncOperation> _keepRemote(
    SyncOperation operation,
    SyncConflict? conflict,
    DateTime now,
  ) async {
    final adapter = _entities?[operation.entityName]?.adapter;
    final data = conflict?.remoteData;
    if (adapter != null && data != null) {
      await adapter.applyRemoteChanges([
        RemoteChange(
          entityName: operation.entityName,
          entityId: operation.entityId,
          type: RemoteChangeType.upsert,
          data: data,
          version: conflict?.remoteVersion,
        ),
      ]);
    }
    return operation.transitionTo(SyncOperationStatus.cancelled, at: now);
  }
}
