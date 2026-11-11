import 'dart:async';
import 'dart:collection';

import 'package:syncflow/syncflow.dart';

/// Computes the response to a request, or throws to simulate a failure.
typedef FakeRequestHandler = FutureOr<SyncResponse> Function(
  SyncRequest request,
);

/// A scriptable [SyncTransport] that records every request.
///
/// Scripted handlers ([enqueueStatus], [enqueueFailure], [enqueueHandler])
/// answer requests first-in, first-out. When the script is empty, [handler]
/// answers (by default: HTTP 200).
final class FakeSyncTransport implements SyncTransport {
  /// Creates a transport answering unscripted requests with [handler].
  FakeSyncTransport({FakeRequestHandler? handler})
      : handler = handler ?? ((_) => SyncResponse(statusCode: 200));

  /// Answers requests when no scripted handler is queued.
  FakeRequestHandler handler;

  final Queue<FakeRequestHandler> _script = Queue();

  /// Every request received, in order, including ones that failed.
  final List<SyncRequest> requests = [];

  /// Whether [close] was called.
  bool get isClosed => _closed;
  bool _closed = false;

  /// Queues a response with [statusCode] and optional [headers].
  void enqueueStatus(int statusCode,
          {Map<String, String> headers = const {}}) =>
      enqueueHandler(
        (_) => SyncResponse(statusCode: statusCode, headers: headers),
      );

  /// Queues a transport failure.
  void enqueueFailure(SyncTransportException exception) =>
      enqueueHandler((_) => throw exception);

  /// Queues an arbitrary handler.
  void enqueueHandler(FakeRequestHandler handler) => _script.add(handler);

  /// Number of scripted handlers not yet consumed.
  int get scriptedRemaining => _script.length;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    if (_closed) throw StateError('FakeSyncTransport has been closed.');
    requests.add(request);
    final next = _script.isNotEmpty ? _script.removeFirst() : handler;
    return next(request);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// A fake backend that deduplicates requests by idempotency key, as a real
/// SyncFlow-compatible server must.
///
/// Use [handle] as a [FakeSyncTransport] handler. The first request with a
/// given key produces a business effect (recorded in [effects]); repeats get
/// the original response without a new effect.
final class FakeIdempotentServer {
  /// Creates a server answering new requests with [respond] (default: 200).
  FakeIdempotentServer({FakeRequestHandler? respond})
      : _respond = respond ?? ((_) => SyncResponse(statusCode: 200));

  final FakeRequestHandler _respond;
  final Map<String, SyncResponse> _responses = {};

  /// Requests that produced a business effect, in order.
  final List<SyncRequest> effects = [];

  /// Number of requests received, including duplicates.
  int received = 0;

  /// Processes [request], deduplicating by its idempotency key.
  Future<SyncResponse> handle(SyncRequest request) async {
    received++;
    final key = request.idempotencyKey;
    if (key != null) {
      final previous = _responses[key];
      if (previous != null) return previous;
    }
    final response = await _respond(request);
    if (response.isSuccessful) {
      effects.add(request);
      if (key != null) _responses[key] = response;
    }
    return response;
  }
}
