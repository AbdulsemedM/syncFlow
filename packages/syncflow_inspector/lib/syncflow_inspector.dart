/// Developer diagnostics for SyncFlow: queue statistics, operation details,
/// conflict inspection, an event timeline and redacted diagnostic exports.
///
/// Disabled in release builds unless explicitly enabled.
library;

export 'src/inspector_event.dart';
export 'src/inspector_models.dart';
export 'src/redactor.dart';
export 'src/sync_inspector.dart';
export 'src/ui/operation_detail_page.dart' show OperationDetailPage;
export 'src/ui/sync_inspector_page.dart'
    show SyncInspectorPage, showSyncInspector;
