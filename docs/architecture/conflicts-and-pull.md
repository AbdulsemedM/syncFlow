# Conflicts and pull synchronization

Step 6 adds conflict resolution for pushed operations and cursor-based pulling
of remote changes. Together they make synchronization bidirectional.

```dart
SyncEntity(
  name: 'customers',
  endpoint: const RestEndpoint.crud('/customers'),
  conflictResolver: ConflictStrategy.serverWins.resolver(),
  pull: const PullEndpoint('/customers/changes'),
  adapter: CustomersAdapter(database), // implements SyncEntityAdapter
)
```

## Conflicts

### Detection

A `409` or `412` response (see `HttpResponseClassifier`) moves the operation to
`conflict`. **In the same transaction**, the engine stores a `SyncConflict`
holding the server's current state and version. `RemoteStateExtractor`
extracts these from the response. By default:

- **data:** `body.current`, else the body itself.
- **version:** the response's server version, else the `ETag` header, else
  `version` in the body.

The record survives restarts until the conflict is resolved, and
`storage.listConflicts(accountId: ...)` lists unresolved ones. Conflict
resolvers run only for real version conflicts, never for transport failures.

### Resolution

| Resolution | Effect |
| --- | --- |
| `UseLocal` | Rebase onto the remote version (or drop the base version if it is unknown, making the write unconditional) and re-queue. Sent on the next run with the same idempotency key. |
| `MergeResolution(payload)` | Like `UseLocal`, with an explicitly merged payload. |
| `UseRemote` | Apply the remote state through the entity's adapter (if both are known) and cancel the local operation. |
| `RequireManualResolution` | Leave it in `conflict` and emit `ConflictDetected`. |

Each resolution is applied in one storage transaction: the operation update,
the adapter call and the removal of the conflict record. In shared-database
mode, the adapter's writes to your tables are part of it.

### Strategies

`SyncEntity.conflictResolver` runs right after a conflict is detected. Without
one, every conflict waits for `engine.resolveConflict(...)`. A resolver that
throws also falls back to manual resolution, so no conflict is ever lost.

| Strategy | Behavior |
| --- | --- |
| `serverWins` | `UseRemote` |
| `clientWins` | `UseLocal` |
| `lastWriteWins` | Compares the local mutation time with the remote `updatedAt`. Manual if the remote time is unknown. |
| `manual` | Always manual |

**Last-write-wins is not a safe default.** Never use it for balances,
financial transactions or anything where overwriting loses meaning. Write a
custom `ConflictResolver` that applies your business rules instead.

Operations that depend on a conflicted operation wait. Once it is resolved,
they proceed: `UseRemote` cancels it, which satisfies its dependents, and
`UseLocal` re-sends it.

## Pull

### Flow

`syncNow()` first pushes local operations, then pulls every entity that has
both a `PullEndpoint` and an adapter, in registration order. For each one:

1. It sends `GET path?cursor=<checkpoint>&limit=<pageSize>`, with no cursor on
   the first pull.
2. It parses the page (`parsePullPage` by default; the format is below).
3. It flags each change whose entity still has unfinished local operations
   (`hasPendingLocalChanges`).
4. **In one storage transaction,** it calls `adapter.applyRemoteChanges(page)`
   and advances the checkpoint.
5. It repeats while `hasMore` is true and the cursor moves forward, up to
   `maxPullPagesPerEntity` pages.

If the adapter throws, the whole page rolls back, including your table writes
in shared-database mode, and the checkpoint stays where it was. The next pull
retries the same page, so pages are never skipped and never half-applied.

### Default feed format

```json
{
  "changes": [
    {"entityId": "c-1", "type": "update", "version": 5, "data": {"name": "Ada"}},
    {"entityId": "c-2", "type": "delete"}
  ],
  "nextCursor": "cursor_002",
  "hasMore": false
}
```

- `type` is `create`, `update`, `upsert` or `delete`.
- Deletions must be sent as tombstones (`delete`).
- `PullEndpoint.parse` accepts a custom parser for other formats.

### Unsynced local edits

A remote change for an entity whose local edits haven't been pushed yet
arrives with `hasPendingLocalChanges: true`. The adapter decides whether to
skip it (the local edit will be pushed and may conflict), merge it, or
overwrite. Pushing before pulling keeps this case rare.

### Expired cursors

If the server answers with `PullEndpoint.expiredCursorStatus` (default `410`)
for a stored cursor, the engine emits `FullResyncStarted` and calls
`adapter.prepareFullResync()`. You can use it to mark local rows as stale, so
rows missing from the full download can be removed. The entity is then pulled
from the beginning. This happens at most once per entity and run; a second
expiry is reported as a failure.

### Failures

Transport errors, non-2xx responses, malformed feeds and adapter errors emit
`PullFailed` and count in `SyncRunResult.pullFailures`. The checkpoint is
unchanged and the remaining entities are still pulled. A `401` pauses the
account, exactly as it does for push.

## Storage contract additions

| Method | Purpose |
| --- | --- |
| `saveConflict` / `getConflict` / `deleteConflict` | Persist conflicts until resolved |
| `listConflicts(accountId)` | Unresolved conflicts, oldest first |

The Drift adapter stores them in `syncflow_conflicts` (schema version 3).
