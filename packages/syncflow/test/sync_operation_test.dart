import 'dart:convert';

import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 3, 1, 9);

  group('SyncOperation construction', () {
    test('applies defaults', () {
      final operation = SyncOperation(
        id: 'op-1',
        accountId: 'account-a',
        entityName: 'customers',
        entityId: 'c-1',
        operationType: SyncOperationType.create,
        payload: const {'name': 'Ada'},
        idempotencyKey: 'idem-1',
        createdAt: t0,
      );

      expect(operation.status, SyncOperationStatus.pending);
      expect(operation.updatedAt, t0);
      expect(operation.attempts, 0);
      expect(operation.dependencies, isEmpty);
      expect(operation.schemaVersion, 1);
      expect(operation.revision, 0);
      expect(operation.isDueAt(t0), isTrue);
    });

    test('normalizes timestamps to UTC', () {
      final local = DateTime(2026, 3, 1, 9);
      final operation = buildTestOperation(id: 'op-1', createdAt: local);
      expect(operation.createdAt.isUtc, isTrue);
      expect(operation.createdAt, local.toUtc());
    });

    test('payload and dependencies are unmodifiable', () {
      final operation = buildTestOperation(id: 'op-1', dependencies: ['op-0']);
      expect(() => operation.payload['x'] = 1, throwsUnsupportedError);
      expect(() => operation.dependencies.add('y'), throwsUnsupportedError);
    });

    test('rejects invalid values', () {
      expect(() => buildTestOperation(id: ''), throwsArgumentError);
      expect(
        () => buildTestOperation(id: 'op-1', accountId: ''),
        throwsArgumentError,
      );
      expect(
        () => buildTestOperation(id: 'op-1', attempts: -1),
        throwsArgumentError,
      );
      expect(
        () => buildTestOperation(id: 'op-1', dependencies: ['op-1']),
        throwsArgumentError,
      );
    });

    test('a lease is required exactly when the operation is in flight', () {
      expect(
        () => buildTestOperation(
          id: 'op-1',
          leaseOwner: 'worker-a',
          leaseExpiresAt: t0,
        ),
        throwsArgumentError,
        reason: 'pending operations cannot hold a lease',
      );
      expect(
        () => SyncOperation(
          id: 'op-1',
          accountId: 'a',
          entityName: 'e',
          entityId: '1',
          operationType: SyncOperationType.create,
          payload: const {},
          idempotencyKey: 'k',
          createdAt: t0,
          status: SyncOperationStatus.leased,
        ),
        throwsArgumentError,
        reason: 'leased operations need a lease',
      );
    });
  });

  group('isDueAt', () {
    test('respects nextAttemptAt for claimable states', () {
      final retry = buildTestOperation(
        id: 'op-1',
        status: SyncOperationStatus.retryScheduled,
        nextAttemptAt: t0,
      );
      expect(
          retry.isDueAt(t0.subtract(const Duration(milliseconds: 1))), isFalse);
      expect(retry.isDueAt(t0), isTrue);
    });

    test('is false for non-claimable states', () {
      for (final status in SyncOperationStatus.values) {
        if (status.isClaimable) continue;
        final operation = buildTestOperation(id: 'op', status: status);
        expect(operation.isDueAt(t0), isFalse, reason: status.name);
      }
    });
  });

  group('copyWith', () {
    test('replaces and clears fields without touching identity', () {
      final operation = buildTestOperation(
        id: 'op-1',
        status: SyncOperationStatus.retryScheduled,
        nextAttemptAt: t0,
        baseVersion: '3',
      );

      final copy = operation.copyWith(
        attempts: 2,
        clearNextAttemptAt: true,
        baseVersion: '4',
      );

      expect(copy.attempts, 2);
      expect(copy.nextAttemptAt, isNull);
      expect(copy.baseVersion, '4');
      expect(copy.id, operation.id);
      expect(copy.idempotencyKey, operation.idempotencyKey);
      expect(copy.status, operation.status);
      expect(operation.nextAttemptAt, t0, reason: 'original unchanged');
    });

    test('omitted nullable fields are preserved', () {
      final operation = buildTestOperation(id: 'op-1', baseVersion: '3');
      expect(operation.copyWith(attempts: 1).baseVersion, '3');
      expect(
        operation.copyWith(clearBaseVersion: true).baseVersion,
        isNull,
      );
    });
  });

  group('JSON', () {
    test('round-trips through jsonEncode/jsonDecode', () {
      final operation = buildTestOperation(
        id: 'op-1',
        status: SyncOperationStatus.sending,
        operationType: SyncOperationType.delete,
        baseVersion: 'etag-9',
        dependencies: ['op-0'],
        attempts: 4,
        createdAt: t0,
        lastError: SyncError(
          category: SyncErrorCategory.timeout,
          message: 'Timed out',
          isRetryable: true,
          occurredAt: t0,
        ),
        revision: 6,
      );

      final decoded = SyncOperation.fromJson(
        jsonDecode(jsonEncode(operation.toJson())) as Map<String, Object?>,
      );

      expect(decoded.toJson(), operation.toJson());
    });

    test('reports malformed records with a FormatException', () {
      final json = buildTestOperation(id: 'op-1').toJson();

      expect(
        () => SyncOperation.fromJson({...json, 'status': 'flying'}),
        throwsFormatException,
      );
      expect(
        () => SyncOperation.fromJson({...json}..remove('idempotencyKey')),
        throwsFormatException,
      );
      expect(
        () => SyncOperation.fromJson({...json, 'createdAt': 'yesterday'}),
        throwsFormatException,
      );
      expect(
        () => SyncOperation.fromJson({
          ...json,
          'dependencies': [1],
        }),
        throwsFormatException,
      );
    });

    test('toString does not expose the payload', () {
      final operation = buildTestOperation(
        id: 'op-1',
        payload: {'password': 'hunter2'},
      );
      expect(operation.toString(), isNot(contains('hunter2')));
    });
  });

  group('SyncError', () {
    test('round-trips through JSON', () {
      final error = SyncError(
        category: SyncErrorCategory.validation,
        message: 'Name is required',
        isRetryable: false,
        httpStatus: 422,
        serverRequestId: 'req-1',
        operationId: 'op-1',
        occurredAt: t0,
      );

      final decoded = SyncError.fromJson(error.toJson());

      expect(decoded.toJson(), error.toJson());
      expect(decoded.toString(), contains('HTTP 422'));
    });
  });
}
