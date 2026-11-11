# SyncFlow

> Offline-first synchronization for Flutter. Keep your database. Keep your
> backend. Sync reliably.

SyncFlow is a modular synchronization engine. It records local mutations as
durable operations and delivers them to an existing REST backend with leases,
retries, dependency ordering and explicit conflict handling. You keep your
current database, HTTP client and state management.

**Status:** early development (`0.1.0-dev`). Not ready for production use.

## Packages

| Package | Purpose | Status |
| --- | --- | --- |
| [`syncflow`](packages/syncflow) | Pure Dart core: operation model, state machine, queue, contracts | In progress |
| [`syncflow_test`](packages/syncflow_test) | In-memory storage, fake clock, ID generator, storage contract tests | In progress |
| `syncflow_drift` | Drift persistence and transactional outbox | Planned |
| `syncflow_dio` | Dio REST transport | Planned |
| `syncflow_flutter` | Lifecycle and connectivity triggers | Planned |
| `syncflow_inspector` | Developer diagnostics UI | Planned |

## Build plan

The full design is in the architecture blueprint. Each step ends with green
analysis and tests.

- [x] **Step 1: Core contracts.** Workspace, operation model, state machine,
  `SyncStorage`/`SyncTransport` contracts, in-memory queue, storage contract
  test suite.
- [ ] **Step 2: Execution engine.** Retry policy with jitter, error
  classification, executor (lease → send → classify → persist), crash
  recovery, fake transport.
- [ ] **Step 3: Drift adapter.** Tables, indexes, migrations, atomic leases,
  shared-transaction outbox; must pass the storage contract suite.
- [ ] **Step 4: Dio adapter.** Request mapping, idempotency headers,
  `Retry-After`, auth hooks, status classification.
- [ ] **Step 5: Entities and dependencies.** Entity registration, REST
  endpoint mapping, dependency gating, temporary-ID rewriting.
- [ ] **Step 6: Conflicts and pull.** Conflict resolvers, cursor-based pull,
  checkpoints, tombstones.
- [ ] **Step 7: Flutter integration.**
- [ ] **Step 8: Inspector.**

## Development

Requires Dart 3.6 or later. This repository is a
[Pub workspace](https://dart.dev/tools/pub/workspaces).

```sh
dart pub get                     # resolve the whole workspace
dart analyze --fatal-infos       # static analysis
dart format .                    # format
(cd packages/syncflow && dart test)
(cd packages/syncflow_test && dart test)
```

## Documentation

- [Operation lifecycle and initial contracts](docs/architecture/operation-lifecycle.md)
- [Architecture decision records](docs/architecture/decisions/)

## License

MIT. See [LICENSE](LICENSE).
