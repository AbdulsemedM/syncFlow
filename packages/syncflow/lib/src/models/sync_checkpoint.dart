/// A position in a remote change stream for one account and entity.
///
/// A checkpoint must only advance after the changes before it have been
/// successfully applied locally.
final class SyncCheckpoint {
  /// Creates a checkpoint.
  SyncCheckpoint({
    required this.accountId,
    required this.entityName,
    required this.cursor,
    required DateTime updatedAt,
  }) : updatedAt = updatedAt.toUtc() {
    if (accountId.isEmpty) {
      throw ArgumentError.value(accountId, 'accountId', 'must not be empty');
    }
    if (entityName.isEmpty) {
      throw ArgumentError.value(entityName, 'entityName', 'must not be empty');
    }
  }

  /// Account or tenant scope the cursor belongs to.
  final String accountId;

  /// Registered entity name the cursor belongs to.
  final String entityName;

  /// Opaque, server-defined cursor value.
  final String cursor;

  /// When the checkpoint was last advanced (UTC).
  final DateTime updatedAt;

  @override
  String toString() =>
      'SyncCheckpoint($accountId/$entityName @ $cursor, $updatedAt)';
}
