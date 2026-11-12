import 'dart:async';

/// A source of connectivity hints: `true` when some network interface is
/// available.
///
/// Connectivity is only a hint. An available interface does not prove that
/// the backend is reachable, and SyncFlow handles failed connections safely
/// either way. It is used to trigger a sync when the network returns and to
/// skip automatic syncs while clearly offline.
abstract interface class ConnectivitySource {
  /// Emits the connectivity state whenever it changes.
  Stream<bool> get onConnectivityChanged;
}

/// Adapts any `Stream<bool>` into a [ConnectivitySource].
///
/// With `connectivity_plus`:
///
/// ```dart
/// StreamConnectivitySource(
///   Connectivity().onConnectivityChanged.map(
///     (results) => !results.contains(ConnectivityResult.none),
///   ),
/// )
/// ```
final class StreamConnectivitySource implements ConnectivitySource {
  /// Wraps [stream]. Repeated identical values are ignored.
  StreamConnectivitySource(Stream<bool> stream)
      : onConnectivityChanged = stream.distinct();

  @override
  final Stream<bool> onConnectivityChanged;
}
