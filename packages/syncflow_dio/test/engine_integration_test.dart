import 'package:dio/dio.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_dio/syncflow_dio.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

import 'fake_adapter.dart';

/// A backend that deduplicates by the Idempotency-Key header, as a real
/// SyncFlow-compatible server must.
final class IdempotentBackend {
  final Map<String, ResponseBody Function()> _seen = {};
  final List<RecordedRequest> effects = [];

  /// Status to answer new requests with; null means 201.
  int? Function(RecordedRequest request) statusFor = (_) => null;

  /// When true, the response of the next new request is lost after the
  /// business effect happened.
  bool loseNextResponse = false;

  Future<ResponseBody> handle(RecordedRequest request, Future<void>? _) async {
    final key = request.header('Idempotency-Key')!;
    final previous = _seen[key];
    if (previous != null) return previous();

    final status = statusFor(request);
    if (status != null) return respond(status: status);

    effects.add(request);
    ResponseBody created() => respond(
          status: 201,
          body: {'id': 'srv-${effects.length}'},
          headers: {
            'ETag': ['"1"'],
          },
        );
    _seen[key] = created;
    if (loseNextResponse) {
      loseNextResponse = false;
      throw DioException.connectionError(
        requestOptions: request.options,
        reason: 'connection reset',
      );
    }
    return created();
  }
}

void main() {
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late OperationQueue queue;
  late FakeAdapter adapter;
  late IdempotentBackend backend;
  late SyncEngine engine;
  late List<SyncEvent> events;
  var signedIn = true;
  var token = 'token-1';
  bool Function() refreshSucceeds = () => false;

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    clock = FakeClock(DateTime.utc(2026, 7, 1, 9));
    queue = OperationQueue(storage: storage, clock: clock);
    backend = IdempotentBackend();
    adapter = FakeAdapter(backend.handle);
    signedIn = true;
    token = 'token-1';
    refreshSucceeds = () => false;

    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    engine = SyncEngine(
      storage: storage,
      transport: DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(
          accessToken: (_) => signedIn ? token : null,
          refresh: (_) => refreshSucceeds(),
        ),
      ),
      activeAccount: () => 'account-a',
      requestBuilder: (operation) => SyncRequest(
        method: SyncHttpMethod.post,
        path: '/${operation.entityName}',
        accountId: operation.accountId,
        body: operation.payload,
      ),
      config: const SyncEngineConfig(maxConcurrentOperations: 1),
      retryPolicy: ExponentialBackoffRetryPolicy(jitter: 0),
      clock: clock,
    );
    events = [];
    engine.events.listen(events.add);
    await engine.initialize();
  });

  tearDown(() async {
    await engine.close();
    await storage.close();
  });

  Future<SyncOperation> createCustomer(String id) => queue.enqueue(
        SyncMutation.create(
          entity: 'customers',
          id: id,
          data: {'name': 'Customer $id'},
        ),
        accountId: 'account-a',
      );

  test('delivers over HTTP and exposes the server response', () async {
    final operation = await createCustomer('c-1');

    final result = await engine.syncNow();
    await pumpEventQueue();

    expect(result.acknowledged, 1);
    final sent = adapter.requests.single;
    expect(sent.uri.toString(), 'https://api.example.test/customers');
    expect(sent.header('Idempotency-Key'), operation.idempotencyKey);
    expect(sent.header('Authorization'), 'Bearer token-1');
    final ack = events.whereType<OperationAcknowledged>().single;
    expect(ack.response.body, {'id': 'srv-1'});
    expect(ack.response.serverVersion, '"1"');
  });

  test('a lost response is retried and deduplicated by the backend', () async {
    backend.loseNextResponse = true;
    final operation = await createCustomer('c-1');

    final first = await engine.syncNow();
    clock.advance(const Duration(seconds: 1));
    final second = await engine.syncNow();

    expect(first.retryScheduled, 1);
    expect(second.acknowledged, 1);
    expect(adapter.requests, hasLength(2));
    expect(backend.effects, hasLength(1));
    expect(
      adapter.requests.map((r) => r.header('Idempotency-Key')).toSet(),
      {operation.idempotencyKey},
    );
  });

  test('503 with Retry-After schedules the retry accordingly', () async {
    final operation = await createCustomer('c-1');
    adapter.handler = (_, __) async => respond(
          status: 503,
          headers: {
            'Retry-After': ['120'],
          },
        );

    await engine.syncNow();

    final stored = (await storage.getOperation(operation.id))!;
    expect(stored.status, SyncOperationStatus.retryScheduled);
    expect(stored.nextAttemptAt, clock.now().add(const Duration(minutes: 2)));
    expect(stored.lastError!.httpStatus, 503);
  });

  test('422 rejects the operation', () async {
    final operation = await createCustomer('c-1');
    backend.statusFor = (_) => 422;

    final result = await engine.syncNow();

    expect(result.rejected, 1);
    expect(
      (await storage.getOperation(operation.id))!.lastError!.category,
      SyncErrorCategory.validation,
    );
  });

  test('an expired token is refreshed transparently', () async {
    await createCustomer('c-1');
    token = 'expired';
    backend.statusFor = (request) =>
        request.header('Authorization') == 'Bearer expired' ? 401 : null;
    refreshSucceeds = () {
      token = 'token-2';
      return true;
    };

    final result = await engine.syncNow();

    expect(result.acknowledged, 1);
    expect(
      adapter.requests.map((r) => r.header('Authorization')),
      ['Bearer expired', 'Bearer token-2'],
    );
  });

  test('an unrecoverable 401 pauses the account until resumed', () async {
    await createCustomer('c-1');
    await createCustomer('c-2');
    backend.statusFor = (_) => 401;

    final paused = await engine.syncNow();

    expect(paused.stopReason, SyncRunStopReason.authenticationRequired);
    expect(engine.isAuthenticationRequired('account-a'), isTrue);

    backend.statusFor = (_) => null;
    engine.resumeAuthentication('account-a');
    final resumed = await engine.syncNow();

    expect(resumed.acknowledged, 2);
  });

  test('signing out pauses delivery without sending anything', () async {
    await createCustomer('c-1');
    signedIn = false;

    final result = await engine.syncNow();

    expect(result.stopReason, SyncRunStopReason.authenticationRequired);
    expect(adapter.requests, isEmpty);
  });
}
