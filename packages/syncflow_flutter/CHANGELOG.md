## 0.6.0-dev.1

- Initial `SyncFlowFlutter` controller: sync on startup, resume (via
  `AppLifecycleListener`), connectivity restored, due retries and an optional
  periodic interval; debounced automatic triggers; offline skipping; optional
  engine pause while backgrounded.
- `SyncStatus` exposed as a `ValueListenable`, with operation counts.
- `ConnectivitySource` and `StreamConnectivitySource` (no plugin dependency).
