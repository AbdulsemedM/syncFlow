# ADR-001: Pure Dart core

- **Status:** Accepted
- **Date:** 2026-11-11

## Context

SyncFlow must work with different local databases, HTTP clients and state
management solutions, and its correctness under failure must be testable
quickly and deterministically.

## Decision

The `syncflow` package depends only on the Dart SDK. Flutter, Drift, Dio and
every other integration live in adapter packages that depend on the core, never
the other way around. Time and identifiers are injected (`Clock`,
`IdGenerator`) so tests are deterministic.

## Alternatives considered

- **A single Flutter package bundling Drift and Dio.** Simpler to start, but it
  forces those dependencies on every user and makes the core untestable without
  Flutter.
- **A core that depends on Drift and abstracts only the transport.** It couples
  the queue to SQL and prevents other storage backends.

## Consequences

- The core runs on the Dart VM and is tested with `dart test`; no Flutter
  tooling is required.
- Adapters must translate backend-specific exceptions into SyncFlow types.
- A reusable contract test suite (`syncflow_test`) is required so every adapter
  is held to the same guarantees.
