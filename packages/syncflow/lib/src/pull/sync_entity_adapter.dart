import 'remote_change.dart';

/// Connects an entity to the application's local database for incoming
/// changes. The application owns the mapping and the business rules.
///
/// Both methods run inside a storage transaction. With a storage that shares
/// the application's database (such as Drift in shared mode), the local writes
/// and the checkpoint advance are committed together: a crash can never skip
/// or re-skip a page.
abstract interface class SyncEntityAdapter {
  /// Applies one page of remote [changes] in order.
  ///
  /// For a change with `hasPendingLocalChanges`, decide explicitly whether to
  /// overwrite, merge or skip: the local edit has not reached the server yet.
  /// Throwing aborts the page; it is retried on the next pull.
  Future<void> applyRemoteChanges(List<RemoteChange> changes);

  /// Called when the server reports that the pull cursor expired, before the
  /// entity is pulled again from the beginning. For example, mark local rows
  /// as stale so that rows missing from the full download can be removed.
  Future<void> prepareFullResync();
}
