# Operation lifecycle and initial contracts

This document records the public-API decisions made while implementing the
core contracts (step 1), including where they refine the original blueprint.

## State machine

```text
pending ─────────► leased, cancelled, rejected (prerequisite rejected)
leased ──────────► sending, pending            (lease released or expired)
sending ─────────► acknowledged, retryScheduled, conflict, rejected,
                   pending                     (crash recovery)
retryScheduled ──► pending, leased, cancelled, rejected (prerequisite rejected)
conflict ────────► pending, cancelled
rejected ────────► pending, cancelled
acknowledged     (terminal)
cancelled        (terminal)
```

Transitions are enforced by `SyncOperation.transitionTo`, which throws
`InvalidStateTransitionException` for anything else. A test in
`packages/syncflow/test/operation_status_test.dart` pins the full 8×8 table.

### Refinements to the blueprint (§9.4)

| Change | Reason |
| --- | --- |
| `sending → pending` | Crash recovery (§11.2) must return an operation whose lease expired mid-request to the queue. The idempotency key is preserved. |
| `retryScheduled → leased` | A due retry can be claimed atomically in one step instead of two writes (`→ pending → leased`). |
| `pending`, `retryScheduled`, `rejected → cancelled` | Lets the application discard work it no longer wants (§20.3 "cancel an eligible operation"). In-flight operations cannot be cancelled. |
| `pending`, `retryScheduled → rejected` | Propagating permanent prerequisite failures (§12.2): a dependent of a rejected operation is rejected with category `dependency` without being sent (step 5). |

## Lease invariant

An operation carries a lease owner and expiry **exactly** when it is in flight
(`leased` or `sending`). The constructor enforces this, and `transitionTo`
assigns, keeps or clears the lease automatically.

## Optimistic concurrency (`revision`)

The blueprint's operation fields (§9.1) are extended with `revision`. Storage
increments it on every write, and `SyncStorage.updateOperation` rejects writes
based on an outdated revision with `StaleOperationException`.

This is how "lease ownership validation" (§8.1) is enforced without SQL-specific
APIs. For example, if worker A's lease expires mid-request and recovery returns
the operation to `pending`, A's late write of `acknowledged` fails instead of
silently overwriting the recovered state. SQL adapters implement it as
`UPDATE ... WHERE id = ? AND revision = ?`.

## Storage contract refinements (§8.1)

- `acquireLease` takes `now` (to check `nextAttemptAt` and stamp `updatedAt`) and
  returns the leased operation instead of a `bool`.
- `releaseLease` takes `now` and returns whether a lease was released.
- `recoverExpiredLeases` returns the number of recovered operations.
- `insertOperations` (atomic batch) was added.
- Eligibility ordering is specified as `createdAt`, then insertion order, so
  same-millisecond mutations are delivered first in, first out.
- Dependencies are **not** evaluated by storage. That is the engine's job (step 5).

All of this is verified by `runSyncStorageContractTests` in `syncflow_test`,
which the Drift adapter must also pass.

## Dependencies are acyclic by construction

`OperationQueue.enqueue` accepts only dependencies that already exist and belong
to the same account. Because an operation can depend only on operations created
before it, cycles cannot form, and no cycle detection is needed at enqueue time.

## Other decisions

- `baseVersion` is a `String?`. Numeric revisions, ETags and other backend
  version tokens all fit.
- Payloads must be JSON-encodable. `InMemorySyncStorage` round-trips through
  JSON to catch violations early.
- `SyncOperation.toString` never includes the payload, so sensitive data does
  not leak into logs.
- Transports return a `SyncResponse` for **every** HTTP status and throw
  `SyncTransportException` only when no status exists (connection errors,
  timeouts). Classification belongs to the engine.
