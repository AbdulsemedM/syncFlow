/// Flutter integration for SyncFlow.
///
/// ```dart
/// final sync = SyncFlowFlutter(engine: engine, connectivity: connectivity)
///   ..start();
///
/// ValueListenableBuilder<SyncStatus>(
///   valueListenable: sync.status,
///   builder: (context, status, _) =>
///       Text('${status.pendingOperations} changes waiting to sync'),
/// );
/// ```
library;

export 'src/connectivity_source.dart';
export 'src/sync_flow_flutter.dart';
export 'src/sync_status.dart';
