/// Records that the server assigned [serverId] to an entity created locally as
/// [localId].
///
/// Mappings are stored when a create is acknowledged, in the same transaction
/// as the acknowledgement. Requests built afterwards resolve local IDs to
/// server IDs, so operations queued against the temporary ID still reach the
/// right server resource.
final class SyncIdMapping {
  /// Creates a mapping.
  SyncIdMapping({
    required this.accountId,
    required this.entityName,
    required this.localId,
    required this.serverId,
    required DateTime createdAt,
  }) : createdAt = createdAt.toUtc() {
    for (final (value, name) in [
      (accountId, 'accountId'),
      (entityName, 'entityName'),
      (localId, 'localId'),
      (serverId, 'serverId'),
    ]) {
      if (value.isEmpty) {
        throw ArgumentError.value(value, name, 'must not be empty');
      }
    }
  }

  /// Account scope of the entity.
  final String accountId;

  /// Registered entity name.
  final String entityName;

  /// The ID the application used when creating the entity offline.
  final String localId;

  /// The ID assigned by the server.
  final String serverId;

  /// When the mapping was recorded (UTC).
  final DateTime createdAt;

  @override
  String toString() =>
      'SyncIdMapping($accountId/$entityName: $localId -> $serverId)';
}
