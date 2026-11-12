import 'package:syncflow/syncflow.dart';

/// A [SyncEntityAdapter] backed by an in-memory "table" of rows, recording
/// every call for assertions.
final class InMemoryEntityAdapter implements SyncEntityAdapter {
  /// Rows by entity id, as last written by remote changes.
  final Map<String, Map<String, Object?>> rows = {};

  /// Every page passed to [applyRemoteChanges], in order.
  final List<List<RemoteChange>> appliedPages = [];

  /// Number of [prepareFullResync] calls.
  int fullResyncs = 0;

  /// When set, [applyRemoteChanges] throws it (after recording nothing).
  Exception? failWith;

  /// Decides whether a change for an entity with pending local edits is
  /// applied. Defaults to skipping such changes.
  bool Function(RemoteChange change) applyOverPendingLocal = (_) => false;

  /// Changes skipped because of pending local edits.
  final List<RemoteChange> skipped = [];

  /// All applied changes, flattened.
  List<RemoteChange> get applied => [for (final page in appliedPages) ...page];

  @override
  Future<void> applyRemoteChanges(List<RemoteChange> changes) async {
    final failure = failWith;
    if (failure != null) throw failure;
    appliedPages.add(changes);
    for (final change in changes) {
      if (change.hasPendingLocalChanges && !applyOverPendingLocal(change)) {
        skipped.add(change);
        continue;
      }
      switch (change.type) {
        case RemoteChangeType.upsert:
          rows[change.entityId] = {...?change.data};
        case RemoteChangeType.delete:
          rows.remove(change.entityId);
      }
    }
  }

  @override
  Future<void> prepareFullResync() async {
    fullResyncs++;
    rows.clear();
  }
}
