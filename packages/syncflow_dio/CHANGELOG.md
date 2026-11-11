## 0.3.0-dev.1

- Initial `DioSyncTransport`: request mapping, `Idempotency-Key` header,
  per-request timeouts, cancellation on `close`, response normalization
  (lower-case headers, JSON decoding, request ID and ETag extraction).
- `SyncAuthentication`: per-account tokens, single-flight refresh on 401 with
  one retry under the same idempotency key.
- Dio failures mapped to safe `SyncTransportException`s that never expose
  request headers.
