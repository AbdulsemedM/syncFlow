import 'package:flutter/widgets.dart';

import '../sync_inspector.dart';

/// Reloads a view's data when the inspector records an event.
///
/// Reloads are coalesced: while one is running, further notifications cause a
/// single extra reload afterwards instead of one per event.
mixin InspectorReloading<W extends StatefulWidget> on State<W> {
  /// The inspector to listen to.
  SyncInspector get inspector;

  /// Loads the view's data and applies it with `setState`.
  Future<void> load();

  /// The error of the last failed load, if any.
  Object? loadError;

  bool _loading = false;
  bool _reloadRequested = false;

  @override
  void initState() {
    super.initState();
    inspector.addListener(reload);
    reload();
  }

  @override
  void dispose() {
    inspector.removeListener(reload);
    super.dispose();
  }

  /// Reloads now, or after the running load finishes.
  Future<void> reload() async {
    if (_loading) {
      _reloadRequested = true;
      return;
    }
    _loading = true;
    try {
      do {
        _reloadRequested = false;
        try {
          await load();
          if (mounted && loadError != null) setState(() => loadError = null);
        } on Object catch (error) {
          if (mounted) setState(() => loadError = error);
        }
      } while (_reloadRequested && mounted);
    } finally {
      _loading = false;
    }
  }
}
