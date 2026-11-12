import 'dart:async';

import '../models/sync_response.dart';
import '../queue/operation.dart';

/// A persisted conflict: the server refused an operation because it was based
/// on an outdated version.
///
/// Stored in the same transaction that moves the operation to `conflict`, so
/// it survives restarts until it is resolved.
final class SyncConflict {
  /// Creates a conflict record.
  SyncConflict({
    required this.operationId,
    required this.accountId,
    required this.entityName,
    required this.entityId,
    required DateTime detectedAt,
    Map<String, Object?>? remoteData,
    this.remoteVersion,
  })  : remoteData = remoteData == null ? null : Map.unmodifiable(remoteData),
        detectedAt = detectedAt.toUtc();

  /// The conflicting operation.
  final String operationId;

  /// Account scope.
  final String accountId;

  /// Entity type.
  final String entityName;

  /// Entity identifier.
  final String entityId;

  /// The server's current state of the entity, when the response included it.
  final Map<String, Object?>? remoteData;

  /// The server's current version, when known. Used to rebase local changes.
  final String? remoteVersion;

  /// When the conflict was detected (UTC).
  final DateTime detectedAt;

  @override
  String toString() =>
      'SyncConflict($operationId, $entityName/$entityId @ $remoteVersion)';
}

/// The server's view of an entity, extracted from a conflict response.
typedef RemoteState = ({Map<String, Object?>? data, String? version});

/// Extracts the remote state from a conflict response.
typedef RemoteStateExtractor = RemoteState Function(SyncResponse response);

/// Default [RemoteStateExtractor]:
///
/// * data: `body.current` if it is an object, else the body if it is an object
/// * version: the response's server version, else its `ETag` header, else
///   `version` in the data or body
RemoteState remoteStateFromBody(SyncResponse response) {
  final body = response.body;
  final data = switch (body) {
    {'current': final Map<String, Object?> current} => current,
    final Map<String, Object?> map => map,
    _ => null,
  };
  final bodyVersion = switch (body) {
    {'version': final Object version} => '$version',
    _ => null,
  };
  final dataVersion = switch (data) {
    {'version': final Object version} => '$version',
    _ => null,
  };
  return (
    data: data,
    version: response.serverVersion ??
        response.header('etag') ??
        dataVersion ??
        bodyVersion,
  );
}

/// How a conflict is settled.
sealed class ConflictResolution {
  const ConflictResolution();
}

/// Keep the local change: rebase it onto the remote version and send it
/// again. Without a known remote version, the change is re-sent without a
/// base version (an unconditional write).
final class UseLocal extends ConflictResolution {
  /// Creates the resolution.
  const UseLocal();
}

/// Keep the server's state: apply it locally through the entity adapter (when
/// one is registered and the state is known) and cancel the local change.
final class UseRemote extends ConflictResolution {
  /// Creates the resolution.
  const UseRemote();
}

/// Send an explicitly merged payload, rebased onto the remote version.
final class MergeResolution extends ConflictResolution {
  /// Creates the resolution with the merged [payload].
  MergeResolution(Map<String, Object?> payload)
      : payload = Map.unmodifiable(payload);

  /// The merged payload to send.
  final Map<String, Object?> payload;
}

/// Leave the conflict for the application or the user to resolve later with
/// `SyncEngine.resolveConflict`.
final class RequireManualResolution extends ConflictResolution {
  /// Creates the resolution.
  const RequireManualResolution();
}

/// Decides how to settle a conflict between the [local] operation and the
/// server's [conflict] state. Must not perform I/O on the synced entity
/// itself; the engine applies the outcome.
typedef ConflictResolver = FutureOr<ConflictResolution> Function(
  SyncOperation local,
  SyncConflict conflict,
);

/// Built-in conflict strategies.
///
/// None is a safe universal default: choose per entity. Last-write-wins in
/// particular must never be used for balances, financial transactions or other
/// data where overwriting loses meaning.
enum ConflictStrategy {
  /// The server's state wins; the local change is discarded.
  serverWins,

  /// The local change wins and is re-sent on top of the server version.
  clientWins,

  /// The newer change wins: the local mutation time against the remote
  /// `updatedAt` timestamp. Falls back to manual resolution when the remote
  /// timestamp is unknown.
  lastWriteWins,

  /// Leave every conflict for manual resolution.
  manual;

  /// The resolver implementing this strategy. [updatedAtField] names the
  /// remote field holding an ISO-8601 modification time (last-write-wins).
  ConflictResolver resolver({String updatedAtField = 'updatedAt'}) =>
      switch (this) {
        serverWins => (_, __) => const UseRemote(),
        clientWins => (_, __) => const UseLocal(),
        manual => (_, __) => const RequireManualResolution(),
        lastWriteWins => (local, conflict) {
            final raw = conflict.remoteData?[updatedAtField];
            final remoteTime = raw is String ? DateTime.tryParse(raw) : null;
            if (remoteTime == null) return const RequireManualResolution();
            return local.createdAt.isAfter(remoteTime.toUtc())
                ? const UseLocal()
                : const UseRemote();
          },
      };
}
