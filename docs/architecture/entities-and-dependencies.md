# Entities and dependencies

Step 5 adds entity registration, REST request mapping, failure propagation
between dependent operations, and temporary-ID rewriting.

## Registering entities

```dart
final entities = SyncEntityRegistry([
  SyncEntity(
    name: 'customers',
    endpoint: const RestEndpoint.crud('/customers'),
  ),
  SyncEntity(
    name: 'accounts',
    endpoint: const RestEndpoint.crud('/accounts'),
    references: {'customerId': 'customers'},
  ),
]);

final builder = RestRequestBuilder(entities: entities, storage: storage);

final engine = SyncEngine(
  storage: storage,
  transport: transport,
  requestBuilder: builder.build,
  entities: entities,
  activeAccount: () => auth.currentAccountId,
);
```

`RestEndpoint.crud('/customers')` maps operations to requests as follows:

| Operation | Request | Body |
| --- | --- | --- |
| create | `POST /customers` | payload |
| update | `PATCH /customers/{id}` | payload |
| delete | `DELETE /customers/{id}` | none |

- `{id}` is URL-encoded.
- A `null` path means that operation type is unsupported for the entity.
- A non-null `baseVersion` is sent as `If-Match`.
- `SyncEntity.requestBuilder` replaces the mapping entirely for endpoints that
  don't follow REST conventions.

A misconfigured operation, such as one for an unknown entity or with no
endpoint for its type, is rejected with category `serialization`. Nothing is
sent.

## Dependencies

An operation depends on its explicit `dependencies`, plus (by default) the
previous unfinished operation for the same entity. Before sending an
operation, the engine checks each dependency:

| Dependency state | Effect on the dependent |
| --- | --- |
| `acknowledged` | satisfied |
| `cancelled` | satisfied: discarded work no longer blocks anything |
| missing | satisfied: acknowledged history may be compacted |
| `rejected` | **the dependent is rejected** with category `dependency`, without being sent |
| anything else | waiting: counted as `blocked` in the run result |

Rejection cascades. If creating a customer fails validation, the account
created for it and the transaction on that account are rejected in the same
run, each pointing at its prerequisite in `lastError`.

### Retrying after a correction

```dart
await queue.retry(customerCreateId); // also re-queues dependents
```

`retry` moves a rejected operation back to `pending` and resets its attempts
and error, keeping its ID and idempotency key. By default it also re-queues,
recursively, every operation that was rejected **because of it** (category
`dependency`). Dependents rejected for their own reasons are left alone. It all
happens in one storage transaction.

## Temporary IDs

Offline-created entities get a local ID, such as `tmp-c1`. When the server
acknowledges the create with a different ID, the engine reads it with
`SyncEntity.serverIdFrom` (default: `id` in a JSON body) and stores a
`SyncIdMapping` **in the same transaction as the acknowledgement**. A crash
can never leave an acknowledged create whose dependents would still be sent to
the temporary ID.

From then on, `RestRequestBuilder` resolves IDs when it builds each request:

- `{id}` in paths: `PATCH /customers/tmp-c1` is sent as `PATCH /customers/srv-100`.
- Fields declared in `references` (a string or a list of strings):
  `{"customerId": "tmp-c1"}` is sent as `{"customerId": "srv-100"}`.

Stored operations are not rewritten. Resolution happens at send time, so it
also covers operations queued after the acknowledgement.

The engine emits `EntityIdAssigned(entityName, localId, serverId)` after the
mapping is stored. Use it to re-key your local rows if you store server IDs.
Until all queued operations for the entity have finished, keep enqueuing
mutations under the local ID. That keeps them in the same per-entity order
chain, and they are sent to the server ID automatically.

## Storage contract additions

| Method | Purpose |
| --- | --- |
| `findDependentOperations(id)` | Operations listing `id` as a dependency, in queue order (exact element match) |
| `saveIdMapping(mapping)` | Upserts a local-to-server ID mapping |
| `resolveServerId(account, entity, localId)` | Looks up a mapping |

The Drift adapter stores mappings in `syncflow_id_mappings` (schema version 2)
and finds dependents with SQLite's `json_each`.
