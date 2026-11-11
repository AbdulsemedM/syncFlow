import '../models/exceptions.dart';
import '../models/sync_error.dart';
import '../utils/json.dart';
import 'operation_status.dart';
import 'operation_type.dart';

const Object _unset = Object();

/// A durable unit of synchronization work.
///
/// Operations are immutable. Lifecycle changes go through [transitionTo], which
/// enforces the state machine documented on [SyncOperationStatus]; other field
/// changes go through [copyWith]. Neither persists anything: callers write the
/// result back through `SyncStorage`.
///
/// [id] and [idempotencyKey] are fixed at creation and remain stable across
/// every retry and crash recovery.
final class SyncOperation {
  /// Creates an operation, validating its invariants.
  ///
  /// [payload] must be JSON-encodable. All timestamps are normalized to UTC.
  /// Throws an [ArgumentError] if an invariant is violated.
  SyncOperation({
    required this.id,
    required this.accountId,
    required this.entityName,
    required this.entityId,
    required this.operationType,
    required Map<String, Object?> payload,
    required this.idempotencyKey,
    required DateTime createdAt,
    DateTime? updatedAt,
    this.status = SyncOperationStatus.pending,
    this.baseVersion,
    List<String> dependencies = const [],
    this.attempts = 0,
    DateTime? lastAttemptAt,
    DateTime? nextAttemptAt,
    this.leaseOwner,
    DateTime? leaseExpiresAt,
    this.lastError,
    this.schemaVersion = 1,
    this.revision = 0,
  })  : payload = Map.unmodifiable(payload),
        dependencies = List.unmodifiable(dependencies),
        createdAt = createdAt.toUtc(),
        updatedAt = (updatedAt ?? createdAt).toUtc(),
        lastAttemptAt = lastAttemptAt?.toUtc(),
        nextAttemptAt = nextAttemptAt?.toUtc(),
        leaseExpiresAt = leaseExpiresAt?.toUtc() {
    _requireNonEmpty(id, 'id');
    _requireNonEmpty(accountId, 'accountId');
    _requireNonEmpty(entityName, 'entityName');
    _requireNonEmpty(entityId, 'entityId');
    _requireNonEmpty(idempotencyKey, 'idempotencyKey');
    if (attempts < 0) {
      throw ArgumentError.value(attempts, 'attempts', 'must not be negative');
    }
    if (schemaVersion < 1) {
      throw ArgumentError.value(schemaVersion, 'schemaVersion', 'must be >= 1');
    }
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision', 'must not be negative');
    }
    if (dependencies.contains(id)) {
      throw ArgumentError.value(
        dependencies,
        'dependencies',
        'an operation cannot depend on itself',
      );
    }
    final hasLease = leaseOwner != null && leaseExpiresAt != null;
    final hasPartialLease = (leaseOwner == null) != (leaseExpiresAt == null);
    if (hasPartialLease || hasLease != status.isInFlight) {
      throw ArgumentError(
        'Operation "$id" in state ${status.name} must '
        '${status.isInFlight ? '' : 'not '}carry a lease owner and expiry.',
      );
    }
  }

  /// Decodes an operation produced by [toJson].
  ///
  /// Throws a [FormatException] if [json] is malformed. Callers must surface
  /// such failures; an unreadable pending operation must never be discarded
  /// silently.
  factory SyncOperation.fromJson(Map<String, Object?> json) {
    final lastError = readOptionalObject(json, 'lastError');
    return SyncOperation(
      id: readField<String>(json, 'id'),
      accountId: readField<String>(json, 'accountId'),
      entityName: readField<String>(json, 'entityName'),
      entityId: readField<String>(json, 'entityId'),
      operationType: readEnum(json, 'operationType', SyncOperationType.values),
      payload: readObject(json, 'payload'),
      status: readEnum(json, 'status', SyncOperationStatus.values),
      idempotencyKey: readField<String>(json, 'idempotencyKey'),
      baseVersion: readField<String?>(json, 'baseVersion'),
      dependencies: readStringList(json, 'dependencies'),
      attempts: readField<int>(json, 'attempts'),
      createdAt: readDateTime(json, 'createdAt'),
      updatedAt: readDateTime(json, 'updatedAt'),
      lastAttemptAt: readOptionalDateTime(json, 'lastAttemptAt'),
      nextAttemptAt: readOptionalDateTime(json, 'nextAttemptAt'),
      leaseOwner: readField<String?>(json, 'leaseOwner'),
      leaseExpiresAt: readOptionalDateTime(json, 'leaseExpiresAt'),
      lastError: lastError == null ? null : SyncError.fromJson(lastError),
      schemaVersion: readField<int>(json, 'schemaVersion'),
      revision: readField<int>(json, 'revision'),
    );
  }

  /// Unique operation identifier.
  final String id;

  /// User, tenant or workspace scope. Operations never execute under another
  /// account's credentials.
  final String accountId;

  /// Registered entity type, for example `customers`.
  final String entityName;

  /// Local or domain identifier of the affected entity.
  final String entityId;

  /// Create, update or delete.
  final SyncOperationType operationType;

  /// Serialized mutation. JSON-compatible and unmodifiable.
  final Map<String, Object?> payload;

  /// Current lifecycle state.
  final SyncOperationStatus status;

  /// Stable server deduplication key, reused for every delivery attempt.
  final String idempotencyKey;

  /// Server version (revision, ETag, ...) observed when the mutation was made.
  final String? baseVersion;

  /// Identifiers of operations that must complete before this one.
  final List<String> dependencies;

  /// Number of delivery attempts made so far.
  final int attempts;

  /// When the operation was created (UTC).
  final DateTime createdAt;

  /// When the operation last changed (UTC).
  final DateTime updatedAt;

  /// When the most recent delivery attempt started (UTC).
  final DateTime? lastAttemptAt;

  /// Earliest time the operation may be claimed (UTC). `null` means now.
  final DateTime? nextAttemptAt;

  /// Worker currently holding the lease. Set exactly when [status] is
  /// in flight.
  final String? leaseOwner;

  /// When the current lease expires (UTC). Set exactly when [status] is
  /// in flight.
  final DateTime? leaseExpiresAt;

  /// Sanitized description of the most recent failure.
  final SyncError? lastError;

  /// Version of the [payload] format, for migrations.
  final int schemaVersion;

  /// Storage revision used for optimistic concurrency.
  ///
  /// Managed by `SyncStorage`: every successful update increments it, and an
  /// update based on an outdated revision is rejected.
  final int revision;

  /// Whether the operation may be claimed by a worker at [now].
  bool isDueAt(DateTime now) =>
      status.isClaimable &&
      (nextAttemptAt == null || !nextAttemptAt!.isAfter(now));

  /// Returns a copy in state [next], enforcing the state machine.
  ///
  /// Entering an in-flight state from a non-in-flight state requires
  /// [leaseOwner] and [leaseExpiresAt]. Moving between in-flight states keeps
  /// the current lease unless new values are supplied. Leaving the in-flight
  /// states clears the lease.
  ///
  /// Throws an [InvalidStateTransitionException] if the transition is not
  /// allowed.
  SyncOperation transitionTo(
    SyncOperationStatus next, {
    required DateTime at,
    String? leaseOwner,
    DateTime? leaseExpiresAt,
  }) {
    if (!status.canTransitionTo(next)) {
      throw InvalidStateTransitionException(
        operationId: id,
        from: status,
        to: next,
      );
    }
    String? owner;
    DateTime? expiresAt;
    if (next.isInFlight) {
      owner = leaseOwner ?? this.leaseOwner;
      expiresAt = leaseExpiresAt ?? this.leaseExpiresAt;
      if (owner == null || expiresAt == null) {
        throw ArgumentError(
          'Entering ${next.name} requires a lease owner and expiry.',
        );
      }
    }
    return _copy(
      status: next,
      updatedAt: at,
      leaseOwner: owner,
      leaseExpiresAt: expiresAt,
    );
  }

  /// Returns a copy with the given non-lifecycle fields replaced.
  ///
  /// Identity fields ([id], [accountId], [idempotencyKey], [createdAt]) and
  /// lifecycle fields ([status], lease) cannot be changed here. Use the
  /// `clear*` flags to reset nullable fields to `null`.
  SyncOperation copyWith({
    String? entityId,
    Map<String, Object?>? payload,
    String? baseVersion,
    bool clearBaseVersion = false,
    List<String>? dependencies,
    int? attempts,
    DateTime? updatedAt,
    DateTime? lastAttemptAt,
    bool clearLastAttemptAt = false,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    SyncError? lastError,
    bool clearLastError = false,
    int? schemaVersion,
    int? revision,
  }) {
    return _copy(
      entityId: entityId,
      payload: payload,
      baseVersion: clearBaseVersion ? null : (baseVersion ?? _unset),
      dependencies: dependencies,
      attempts: attempts,
      updatedAt: updatedAt,
      lastAttemptAt: clearLastAttemptAt ? null : (lastAttemptAt ?? _unset),
      nextAttemptAt: clearNextAttemptAt ? null : (nextAttemptAt ?? _unset),
      lastError: clearLastError ? null : (lastError ?? _unset),
      schemaVersion: schemaVersion,
      revision: revision,
    );
  }

  /// Encodes this operation as a JSON-compatible map.
  Map<String, Object?> toJson() => {
        'id': id,
        'accountId': accountId,
        'entityName': entityName,
        'entityId': entityId,
        'operationType': operationType.name,
        'payload': payload,
        'status': status.name,
        'idempotencyKey': idempotencyKey,
        'baseVersion': baseVersion,
        'dependencies': dependencies,
        'attempts': attempts,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
        'nextAttemptAt': nextAttemptAt?.toIso8601String(),
        'leaseOwner': leaseOwner,
        'leaseExpiresAt': leaseExpiresAt?.toIso8601String(),
        'lastError': lastError?.toJson(),
        'schemaVersion': schemaVersion,
        'revision': revision,
      };

  /// Deliberately omits the payload, which may contain sensitive data.
  @override
  String toString() => 'SyncOperation($id, ${operationType.name} '
      '$entityName/$entityId, ${status.name}, attempts: $attempts, '
      'revision: $revision)';

  // Private copy that can also change lifecycle fields and clear nullable
  // values. `_unset` means "keep the current value".
  SyncOperation _copy({
    String? entityId,
    Map<String, Object?>? payload,
    SyncOperationStatus? status,
    Object? baseVersion = _unset,
    List<String>? dependencies,
    int? attempts,
    DateTime? updatedAt,
    Object? lastAttemptAt = _unset,
    Object? nextAttemptAt = _unset,
    Object? leaseOwner = _unset,
    Object? leaseExpiresAt = _unset,
    Object? lastError = _unset,
    int? schemaVersion,
    int? revision,
  }) {
    T? pick<T>(Object? value, T? current) =>
        identical(value, _unset) ? current : value as T?;

    return SyncOperation(
      id: id,
      accountId: accountId,
      entityName: entityName,
      entityId: entityId ?? this.entityId,
      operationType: operationType,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      idempotencyKey: idempotencyKey,
      baseVersion: pick<String>(baseVersion, this.baseVersion),
      dependencies: dependencies ?? this.dependencies,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastAttemptAt: pick<DateTime>(lastAttemptAt, this.lastAttemptAt),
      nextAttemptAt: pick<DateTime>(nextAttemptAt, this.nextAttemptAt),
      leaseOwner: pick<String>(leaseOwner, this.leaseOwner),
      leaseExpiresAt: pick<DateTime>(leaseExpiresAt, this.leaseExpiresAt),
      lastError: pick<SyncError>(lastError, this.lastError),
      schemaVersion: schemaVersion ?? this.schemaVersion,
      revision: revision ?? this.revision,
    );
  }

  static void _requireNonEmpty(String value, String name) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
  }
}
