# SyncFlow

> Offline-first synchronization for Flutter. Keep your database. Keep your
> backend. Sync reliably.

SyncFlow is a modular synchronization engine. It records local mutations as
durable operations and delivers them to an existing REST backend with leases,
retries, dependency ordering and explicit conflict handling. You keep your
current database, HTTP client and state management.

**Status:** early development (`0.7.0-dev`). Not ready for production use.

## Packages

| Package | Purpose | Status |
| --- | --- | --- |
| [`syncflow`](packages/syncflow) | Pure Dart core: operation model, state machine, queue, contracts | In progress |
| [`syncflow_test`](packages/syncflow_test) | In-memory storage, fake clock, ID generator, storage contract tests | In progress |
| [`syncflow_drift`](packages/syncflow_drift) | Drift persistence and transactional outbox | In progress |
| [`syncflow_dio`](packages/syncflow_dio) | Dio REST transport | In progress |
| [`syncflow_flutter`](packages/syncflow_flutter) | Lifecycle and connectivity triggers, sync status | In progress |
| [`syncflow_inspector`](packages/syncflow_inspector) | Developer diagnostics UI, redacted exports | In progress |

## Build plan

The full design is in the architecture blueprint. Each step ends with green
analysis and tests.

- [x] **Step 1: Core contracts.** Workspace, operation model, state machine,
  `SyncStorage`/`SyncTransport` contracts, in-memory queue, storage contract
  test suite.
- [x] **Step 2: Execution engine.** Retry policy with jitter, error
  classification, executor (lease → send → classify → persist), crash
  recovery, fake transport.
- [x] **Step 3: Drift adapter.** Tables, indexes, migrations, atomic leases,
  shared-transaction outbox; must pass the storage contract suite.
- [x] **Step 4: Dio adapter.** Request mapping, idempotency headers,
  `Retry-After`, auth hooks, status classification.
- [x] **Step 5: Entities and dependencies.** Entity registration, REST
  endpoint mapping, dependency gating, temporary-ID rewriting.
- [x] **Step 6: Conflicts and pull.** Conflict resolvers, cursor-based pull,
  checkpoints, tombstones.
- [x] **Step 7: Flutter integration.** Lifecycle, connectivity and retry triggers;
  listenable sync status.
- [x] **Step 8: Inspector.** Queue statistics, operation details, conflict
  inspection, event timeline, safe developer actions, redacted exports.

## Development

The core packages require Dart 3.6 or later; `syncflow_flutter` and
`syncflow_inspector` require Flutter 3.27 or later. This repository is a
[Pub workspace](https://dart.dev/tools/pub/workspaces).

```sh
flutter pub get                  # resolve the whole workspace (it contains a Flutter package)
dart analyze --fatal-infos       # static analysis
dart format .                    # format
(cd packages/syncflow && dart test)
(cd packages/syncflow_test && dart test)
(cd packages/syncflow_drift && dart test)   # needs SQLite (libsqlite3-dev on Linux)
(cd packages/syncflow_dio && dart test)
(cd packages/syncflow_flutter && flutter test)
(cd packages/syncflow_inspector && flutter test)
```

## Documentation

- [Operation lifecycle and initial contracts](docs/architecture/operation-lifecycle.md)
- [Execution engine](docs/architecture/execution-engine.md)
- [Entities and dependencies](docs/architecture/entities-and-dependencies.md)
- [Conflicts and pull](docs/architecture/conflicts-and-pull.md)
- [Drift adapter and transactional outbox](packages/syncflow_drift/README.md)
- [Dio transport](packages/syncflow_dio/README.md)
- [Flutter integration](packages/syncflow_flutter/README.md)
- [Inspector](packages/syncflow_inspector/README.md)
- [Architecture decision records](docs/architecture/decisions/)

## License

MIT. See [LICENSE](LICENSE).
