# syncflow_dio

[Dio](https://pub.dev/packages/dio) REST transport for
[SyncFlow](../syncflow).

- **Uses your Dio instance.** It keeps your base URL, interceptors and adapters.
- **Idempotency.** The operation's key is sent as `Idempotency-Key` on every
  attempt, and it always wins over headers set by a request builder.
- **Per-account credentials.** Tokens come from your auth layer for the
  request's own account, on every attempt. SyncFlow never stores them.
- **Token refresh.** After a 401, it refreshes once and retries with the same
  idempotency key. Concurrent 401s for one account share a single refresh. If
  refresh fails, the 401 reaches the engine, which pauses that account until
  you call `resumeAuthentication`.
- **Contract-compliant.** Every HTTP status comes back as a response. Only
  failures with no response (timeouts, connection errors, cancellation) throw a
  `SyncTransportException`, with a fixed safe message and a cause that never
  includes request headers.

## Usage

```dart
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

final transport = DioSyncTransport(
  dio: dio,
  authentication: SyncAuthentication(
    accessToken: (accountId) => auth.accessTokenFor(accountId),
    refresh: (accountId) => auth.refresh(accountId),
  ),
  defaultTimeout: const Duration(seconds: 30),
);

final engine = SyncEngine(
  storage: storage,
  transport: transport,
  activeAccount: () => auth.currentAccountId,
  requestBuilder: (operation) => SyncRequest(
    method: switch (operation.operationType) {
      SyncOperationType.create => SyncHttpMethod.post,
      SyncOperationType.update => SyncHttpMethod.patch,
      SyncOperationType.delete => SyncHttpMethod.delete,
    },
    path: operation.operationType == SyncOperationType.create
        ? '/${operation.entityName}'
        : '/${operation.entityName}/${operation.entityId}',
    accountId: operation.accountId,
    body: operation.operationType == SyncOperationType.delete
        ? null
        : operation.payload,
  ),
);
```

Keep the engine's `leaseDuration` (default 2 minutes) comfortably above
`defaultTimeout`.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `authentication` | none | Token provider, optional refresh, header name and scheme |
| `idempotencyHeader` | `Idempotency-Key` | Header carrying the idempotency key |
| `requestIdHeader` | `x-request-id` | Response header mapped to `serverRequestId` |
| `versionHeader` | `etag` | Response header mapped to `serverVersion` |
| `defaultTimeout` | Dio's options | Connect, send and receive timeout per request |
| `closeDio` | `false` | Whether `close()` also closes the Dio instance |

## Security notes

- An interceptor such as Dio's `LogInterceptor(requestHeader: true)` would log
  the `Authorization` header. Disable header logging in production.
- `SyncTransportException.cause` holds the low-level error (for example, a
  `SocketException`), never the `DioException` with its request options.
