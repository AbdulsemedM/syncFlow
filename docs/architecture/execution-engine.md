# Execution engine

Step 2 adds delivery: `SyncEngine` claims eligible operations, sends them
through a `SyncTransport`, classifies the result and stores the next state.

## Delivering one operation

```text
acquireLease ─► build request ─► mark sending (attempts+1) ─► transport.send
                     │                    │                         │
            builder throws         stale write                classify
                     ▼                    ▼                         ▼
                 rejected           lease lost        persist next state ─► emit event
```

| Outcome | Next state | Notes |
| --- | --- | --- |
| succeeded (2xx) | `acknowledged` | `lastError` cleared |
| retryable (5xx, 408, 429, network, timeout) | `retryScheduled` | `nextAttemptAt` from `RetryPolicy`; `rejected` when the policy gives up |
| unauthenticated (401) | `pending` | Account paused until `resumeAuthentication` |
| rejected (400, 403, 422, other 4xx) | `rejected` | Needs application attention |
| conflicted (409, 412) | `conflict` | Resolution comes in step 6 |

Guarantees:

- **The idempotency key cannot be overridden.** The engine always replaces
  the request's account, idempotency key and operation ID with the
  operation's own values, whatever the `SyncRequestBuilder` returns.
- **Events follow storage.** An event is emitted only after the new state is
  stored.
- **Stale results are dropped.** If a lease expires mid-request and another
  worker recovers the operation, the late result fails the revision check and
  is discarded (`OperationLeaseLost`). The operation is delivered again with
  the same idempotency key, and the server deduplicates.
- **Exceptions are classified; `Error`s propagate.** Exceptions from the
  builder or transport become outcomes. Programming errors surface to the
  `syncNow` caller, and the operation is recovered when its lease expires.

## A run

1. Stop early if the engine is closed or paused, no account is active, or the
   account needs re-authentication.
2. Recover expired leases.
3. Repeat until nothing is ready:
   - Fetch the active account's eligible operations.
   - Check each operation's dependencies (see
     [entities and dependencies](entities-and-dependencies.md)): ready,
     waiting (`blocked`), or failed. A failed operation is rejected without
     being sent, which can cascade to its own dependents.
   - Deliver the rest with at most `maxConcurrentOperations` in flight.
   - Before each operation, re-check the account, pause and close state.
4. Emit `SyncRunCompleted` with a `SyncRunResult`.

An operation is attempted **at most once per run**, so a run always terminates,
even with zero-delay retries. Overlapping `syncNow()` calls are merged: callers
that arrive during a run share a single follow-up run.

## Ordering within an entity

`OperationQueue` (with `serializeEntityOperations: true`, the default) makes
each new operation depend on the previous unfinished operation for the same
entity. Together with dependency gating, this means an update is never sent
before the create it follows. Each enqueue runs in one storage transaction,
so concurrent mutations of one entity form a chain.

## Crash recovery

`initialize()` and the start of every run call `recoverExpiredLeases`. Only
**expired** leases are recovered, because an unexpired lease may belong to
another live worker such as a background isolate. Recovered operations keep
their ID, idempotency key and attempt count.

`leaseDuration` (default 2 minutes) must comfortably exceed the transport
timeout.

## Retry policy

`ExponentialBackoffRetryPolicy`: `min(maxDelay, baseDelay · 2^(n−1))`, shortened
by a random jitter of up to `jitter` (default 50%). A `Retry-After` header
replaces the computed delay (no jitter), capped at `maxRetryAfter`.
`maxAttempts` defaults to unlimited, because offline-first devices may be
offline for days.

## Known limitations

- Acknowledgement metadata (such as the server version) is available in
  `OperationAcknowledged` but is not persisted on the operation.
- A `conflict` dependency keeps its dependents waiting until the conflict is
  resolved (step 6).
