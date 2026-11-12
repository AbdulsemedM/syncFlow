## 0.7.0-dev.1

- `listOperations` in `InMemorySyncStorage` and the contract suite.

## 0.6.0-dev.1

- `countOperations` in `InMemorySyncStorage` and the contract suite.

## 0.5.0-dev.1

- `InMemoryEntityAdapter` for pull and conflict tests.
- Conflict storage in `InMemorySyncStorage` and the contract suite.

## 0.4.0-dev.1

- In-memory and contract-test support for dependent lookup and ID mappings.

## 0.3.0-dev.1

- `InMemorySyncStorage.runInTransaction` with savepoint rollback; all calls
  are serialized like a database's writers.
- Transaction contract tests: commit, rollback, nested savepoints, isolation
  from outside readers.

## 0.2.0-dev.1

- `FakeSyncTransport`: scriptable transport that records requests.
- `FakeIdempotentServer`: fake backend that deduplicates by idempotency key.
- `InMemorySyncStorage.findLatestActiveOperation` and matching contract tests.

## 0.1.0-dev.1

- `InMemorySyncStorage`, `FakeClock`, `SequentialIdGenerator`,
  `buildTestOperation`.
- `runSyncStorageContractTests` storage contract suite.
