import 'package:syncflow/syncflow.dart';

/// Builds a valid [SyncOperation] with sensible defaults for tests.
///
/// In-flight statuses get a default lease (`worker-1`, expiring one minute
/// after [createdAt]) unless [leaseOwner] and [leaseExpiresAt] are given.
SyncOperation buildTestOperation({
  required String id,
  String accountId = 'account-a',
  String entityName = 'customers',
  String? entityId,
  SyncOperationType operationType = SyncOperationType.create,
  Map<String, Object?> payload = const {'name': 'Example'},
  SyncOperationStatus status = SyncOperationStatus.pending,
  String? idempotencyKey,
  String? baseVersion,
  List<String> dependencies = const [],
  int attempts = 0,
  DateTime? createdAt,
  DateTime? nextAttemptAt,
  String? leaseOwner,
  DateTime? leaseExpiresAt,
  SyncError? lastError,
  int revision = 0,
}) {
  final created = createdAt ?? DateTime.utc(2026);
  final inFlight = status.isInFlight;
  return SyncOperation(
    id: id,
    accountId: accountId,
    entityName: entityName,
    entityId: entityId ?? 'entity-$id',
    operationType: operationType,
    payload: payload,
    status: status,
    idempotencyKey: idempotencyKey ?? 'idem-$id',
    baseVersion: baseVersion,
    dependencies: dependencies,
    attempts: attempts,
    createdAt: created,
    nextAttemptAt: nextAttemptAt,
    leaseOwner: leaseOwner ?? (inFlight ? 'worker-1' : null),
    leaseExpiresAt: leaseExpiresAt ??
        (inFlight ? created.add(const Duration(minutes: 1)) : null),
    lastError: lastError,
    revision: revision,
  );
}
