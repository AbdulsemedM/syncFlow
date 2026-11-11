import 'operation_type.dart';

/// A request to record a local change for remote delivery.
///
/// A mutation becomes a durable `SyncOperation` when it is enqueued, at which
/// point it receives a stable operation ID and idempotency key.
final class SyncMutation {
  SyncMutation._({
    required this.type,
    required this.entity,
    required this.id,
    required Map<String, Object?> data,
    required List<String> dependencies,
    this.baseVersion,
    this.idempotencyKey,
    this.schemaVersion = 1,
  })  : data = Map.unmodifiable(data),
        dependencies = List.unmodifiable(dependencies.toSet()) {
    if (entity.isEmpty) {
      throw ArgumentError.value(entity, 'entity', 'must not be empty');
    }
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
  }

  /// A local creation of entity [id] of type [entity].
  factory SyncMutation.create({
    required String entity,
    required String id,
    required Map<String, Object?> data,
    List<String> dependencies = const [],
    String? idempotencyKey,
    int schemaVersion = 1,
  }) =>
      SyncMutation._(
        type: SyncOperationType.create,
        entity: entity,
        id: id,
        data: data,
        dependencies: dependencies,
        idempotencyKey: idempotencyKey,
        schemaVersion: schemaVersion,
      );

  /// A local modification of entity [id], based on server [baseVersion].
  factory SyncMutation.update({
    required String entity,
    required String id,
    required Map<String, Object?> data,
    String? baseVersion,
    List<String> dependencies = const [],
    String? idempotencyKey,
    int schemaVersion = 1,
  }) =>
      SyncMutation._(
        type: SyncOperationType.update,
        entity: entity,
        id: id,
        data: data,
        baseVersion: baseVersion,
        dependencies: dependencies,
        idempotencyKey: idempotencyKey,
        schemaVersion: schemaVersion,
      );

  /// A local deletion of entity [id], based on server [baseVersion].
  factory SyncMutation.delete({
    required String entity,
    required String id,
    String? baseVersion,
    List<String> dependencies = const [],
    String? idempotencyKey,
  }) =>
      SyncMutation._(
        type: SyncOperationType.delete,
        entity: entity,
        id: id,
        data: const {},
        baseVersion: baseVersion,
        dependencies: dependencies,
        idempotencyKey: idempotencyKey,
      );

  /// Kind of change.
  final SyncOperationType type;

  /// Registered entity name, for example `customers`.
  final String entity;

  /// Identifier of the affected entity.
  final String id;

  /// JSON-compatible representation of the change.
  final Map<String, Object?> data;

  /// Server version the change was based on, if known.
  final String? baseVersion;

  /// Operation IDs that must complete first. Duplicates are removed.
  final List<String> dependencies;

  /// Explicit idempotency key. When `null`, one is generated at enqueue time.
  final String? idempotencyKey;

  /// Version of the [data] format.
  final int schemaVersion;
}
