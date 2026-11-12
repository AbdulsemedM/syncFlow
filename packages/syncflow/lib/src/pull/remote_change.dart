import '../models/sync_response.dart';

/// Kind of remote change.
enum RemoteChangeType {
  /// The entity was created or updated; `data` holds its current state.
  upsert,

  /// The entity was deleted (a tombstone).
  delete,
}

/// A change made on the server, delivered by pull synchronization.
final class RemoteChange {
  /// Creates a change.
  RemoteChange({
    required this.entityName,
    required this.entityId,
    required this.type,
    Map<String, Object?>? data,
    this.version,
    this.hasPendingLocalChanges = false,
  }) : data = data == null ? null : Map.unmodifiable(data);

  /// Entity type.
  final String entityName;

  /// Server identifier of the entity.
  final String entityId;

  /// Upsert or delete.
  final RemoteChangeType type;

  /// Current state for upserts; usually `null` for deletes.
  final Map<String, Object?>? data;

  /// Server version of the entity after the change, if provided.
  final String? version;

  /// Whether local operations for this entity are still waiting to be
  /// delivered. Applying the change blindly would overwrite those unsynced
  /// local edits; the adapter decides how to handle it.
  final bool hasPendingLocalChanges;

  /// Returns a copy with [hasPendingLocalChanges] set.
  RemoteChange withPendingLocalChanges(bool value) => RemoteChange(
        entityName: entityName,
        entityId: entityId,
        type: type,
        data: data,
        version: version,
        hasPendingLocalChanges: value,
      );

  @override
  String toString() => 'RemoteChange(${type.name} $entityName/$entityId'
      '${version == null ? '' : ' @ $version'})';
}

/// One page of remote changes.
final class PullPage {
  /// Creates a page.
  PullPage({
    required List<RemoteChange> changes,
    required this.nextCursor,
    required this.hasMore,
  }) : changes = List.unmodifiable(changes);

  /// Changes in server order.
  final List<RemoteChange> changes;

  /// Cursor to resume after this page; `null` keeps the current checkpoint.
  final String? nextCursor;

  /// Whether more changes are immediately available.
  final bool hasMore;
}

/// Parses a pull response for [entityName].
typedef PullPageParser = PullPage Function(
  SyncResponse response,
  String entityName,
);

/// Parses the SyncFlow pull protocol:
///
/// ```json
/// {
///   "changes": [
///     {"entityId": "c-1", "type": "update", "version": 5, "data": {...}},
///     {"entityId": "c-2", "type": "delete"}
///   ],
///   "nextCursor": "cursor_002",
///   "hasMore": false
/// }
/// ```
///
/// `type` is `create`, `update`, `upsert` or `delete`; `id` is accepted for
/// `entityId`. Throws a [FormatException] for anything else.
PullPage parsePullPage(SyncResponse response, String entityName) {
  final body = response.body;
  if (body is! Map<String, Object?>) {
    throw const FormatException('Pull response body is not a JSON object.');
  }
  final rawChanges = body['changes'] ?? const <Object?>[];
  if (rawChanges is! List<Object?>) {
    throw const FormatException('"changes" is not a list.');
  }
  final nextCursor = body['nextCursor'];
  final hasMore = body['hasMore'] ?? false;
  if (nextCursor is! String? || hasMore is! bool) {
    throw const FormatException('Invalid "nextCursor" or "hasMore".');
  }
  return PullPage(
    changes: [for (final raw in rawChanges) _parseChange(raw, entityName)],
    nextCursor: nextCursor,
    hasMore: hasMore,
  );
}

RemoteChange _parseChange(Object? raw, String entityName) {
  if (raw is! Map<String, Object?>) {
    throw const FormatException('A change is not a JSON object.');
  }
  final id = raw['entityId'] ?? raw['id'];
  final entityId = switch (id) {
    final String s when s.isNotEmpty => s,
    final num n => '$n',
    _ => throw const FormatException('A change has no entity id.'),
  };
  final type = switch (raw['type']) {
    'create' || 'update' || 'upsert' => RemoteChangeType.upsert,
    'delete' => RemoteChangeType.delete,
    _ => throw FormatException('Unknown change type for "$entityId".'),
  };
  final data = raw['data'];
  if (data is! Map<String, Object?>?) {
    throw FormatException('Invalid data for "$entityId".');
  }
  if (type == RemoteChangeType.upsert && data == null) {
    throw FormatException('Upsert of "$entityId" has no data.');
  }
  final version = raw['version'];
  return RemoteChange(
    entityName: entityName,
    entityId: entityId,
    type: type,
    data: data,
    version: version == null ? null : '$version',
  );
}
