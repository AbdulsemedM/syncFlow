# syncflow_inspector

Developer diagnostics for [SyncFlow](../syncflow). See what is in the queue,
why an operation failed, and what the engine did, with payloads redacted.

## Usage

```dart
final inspector = SyncInspector(
  engine: engine,
  storage: storage,
  redactor: const SyncRedactor().withKeys(['email', 'phone']),
)..start(); // start right after creating the engine to capture every event

// From a debug menu or a hidden gesture:
IconButton(
  icon: const Icon(Icons.bug_report),
  onPressed: () => showSyncInspector(context, inspector),
);

// On shutdown:
inspector.dispose(); // the engine and storage are not closed for you
```

## Production

The inspector is **disabled in release builds** unless you pass
`enabled: true`. A disabled inspector:

- records nothing;
- makes `showSyncInspector` a no-op, so a debug button can stay in place;
- throws a `StateError` from every query and action.

## What it shows

**Overview**
- Active account, syncing, paused and authentication-required state.
- Pending, completed, rejected, conflict and cancelled counts.
- The last run and the last successful sync.
- Unresolved conflicts.

**Operations**
- Newest first, filterable: pending, failed, completed, cancelled.

**Operation detail**
- ID, masked idempotency key, timestamps, attempts and next retry.
- The last error: category, HTTP status, server request ID and its sanitized message.
- Dependencies (and whether they are satisfied) and dependents.
- The server's state for a conflict.
- The redacted payload and the operation's event history.

**Timeline**
- Engine events since `start()`, newest first, capped at `maxTimelineEvents`
  (200 by default).

## Actions

| Action | Allowed when | Goes through |
| --- | --- | --- |
| Retry | The operation is rejected | `OperationQueue.retry` (re-queues dependents rejected because of it) |
| Cancel | Not in flight and not terminal | `OperationQueue.cancel` |
| Keep local / Use remote | The operation is in conflict | `SyncEngine.resolveConflict` |
| Pause / resume | Always | `SyncEngine.pause` / `resume` |
| Sync now | Always | `SyncEngine.syncNow` |

Actions use the same APIs as application code. They re-check the stored state
and never bypass the state machine: cancelling an operation that was just
delivered fails with `InvalidStateTransitionException`, and the page reports
the failure. Actions are recorded in the timeline. Everything is limited to
the active account; other accounts' operations are invisible and cannot be
changed.

## Sensitive data

- **Payloads and remote conflict states** pass through `SyncRedactor`. It
  matches keys case-insensitively and ignoring `_`, `-` and `.`:
  - Fragments such as `password`, `token`, `secret`, `apikey` and
    `authorization` are matched anywhere in the key (`newPassword`,
    `refresh_token`).
  - Short keys such as `pin`, `cvv` and `ssn` are matched exactly.
  - Add your own keys with `withKeys`. Use `SyncRedactor(maskAllValues: true)`
    to keep only the payload's shape.
- **Idempotency keys** are masked except for the last four characters. Pass
  `exposeIdempotencyKeys: true` to show them in full.
- **Timeline entries** never contain payloads or response bodies.

### Exports

`exportReport()`, or the export button, produces a JSON report:

- Counts, the last run, up to 500 operations, conflicts and the timeline.
- The account ID is replaced by a placeholder unless you pass
  `includeAccountId: true`.
- `includePayloads: false` leaves out payloads and remote states entirely.

Redaction only knows the keys it is told about, so **treat every export as
sensitive**. Share exports only through channels approved for user data.

## Limitations

- **Timeline and history are in memory.** They cover events since `start()`
  and are lost when the app exits; the queue itself is read from storage.
- **"Last successful sync" is per session.** It is observed since `start()`,
  not persisted.
- **Acknowledged operations are kept until you delete them.** The
  "Completed" list grows with them; SyncFlow does not compact them yet.
