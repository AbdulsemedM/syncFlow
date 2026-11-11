import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

typedef S = SyncOperationStatus;

/// The specification (blueprint §9.4 plus documented additions), written out
/// independently of the implementation so accidental changes are caught.
const expectedTransitions = <S, Set<S>>{
  S.pending: {S.leased, S.cancelled},
  S.leased: {S.sending, S.pending},
  S.sending: {
    S.acknowledged,
    S.retryScheduled,
    S.conflict,
    S.rejected,
    S.pending
  },
  S.retryScheduled: {S.pending, S.leased, S.cancelled},
  S.conflict: {S.pending, S.cancelled},
  S.rejected: {S.pending, S.cancelled},
  S.acknowledged: {},
  S.cancelled: {},
};

void main() {
  group('SyncOperationStatus transition table', () {
    for (final from in S.values) {
      for (final to in S.values) {
        final allowed = expectedTransitions[from]!.contains(to);
        test('${from.name} -> ${to.name} is ${allowed ? '' : 'not '}allowed',
            () {
          expect(from.canTransitionTo(to), allowed);
        });
      }
    }

    test('only acknowledged and cancelled are terminal', () {
      expect(
        S.values.where((s) => s.isTerminal),
        [S.acknowledged, S.cancelled],
      );
    });

    test('no state transitions to itself', () {
      for (final status in S.values) {
        expect(status.canTransitionTo(status), isFalse, reason: status.name);
      }
    });

    test('allowed transitions cannot be modified', () {
      expect(
        () => S.pending.allowedTransitions.add(S.acknowledged),
        throwsUnsupportedError,
      );
    });
  });

  group('SyncOperation.transitionTo', () {
    final t0 = DateTime.utc(2026, 1, 1);
    final t1 = t0.add(const Duration(seconds: 5));
    final expiry = t0.add(const Duration(minutes: 1));

    test('applies a valid transition and stamps updatedAt', () {
      final operation = buildTestOperation(id: 'op-1', createdAt: t0);

      final leased = operation.transitionTo(
        S.leased,
        at: t1,
        leaseOwner: 'worker-a',
        leaseExpiresAt: expiry,
      );

      expect(leased.status, S.leased);
      expect(leased.updatedAt, t1);
      expect(leased.leaseOwner, 'worker-a');
      expect(leased.leaseExpiresAt, expiry);
      expect(leased.id, operation.id);
      expect(leased.idempotencyKey, operation.idempotencyKey);
      expect(operation.status, S.pending, reason: 'original is immutable');
    });

    test('throws a typed exception for an invalid transition', () {
      final operation = buildTestOperation(id: 'op-1');

      expect(
        () => operation.transitionTo(S.acknowledged, at: t1),
        throwsA(
          isA<InvalidStateTransitionException>()
              .having((e) => e.operationId, 'operationId', 'op-1')
              .having((e) => e.from, 'from', S.pending)
              .having((e) => e.to, 'to', S.acknowledged),
        ),
      );
    });

    test('terminal operations cannot change state', () {
      for (final terminal in [S.acknowledged, S.cancelled]) {
        final operation = buildTestOperation(id: 'op', status: terminal);
        for (final next in S.values) {
          expect(
            () => operation.transitionTo(next, at: t1),
            throwsA(isA<InvalidStateTransitionException>()),
          );
        }
      }
    });

    test('entering an in-flight state requires a lease', () {
      final operation = buildTestOperation(id: 'op-1');
      expect(
        () => operation.transitionTo(S.leased, at: t1),
        throwsArgumentError,
      );
    });

    test('moving between in-flight states keeps the lease', () {
      final leased = buildTestOperation(
        id: 'op-1',
        status: S.leased,
        leaseOwner: 'worker-a',
        leaseExpiresAt: expiry,
      );

      final sending = leased.transitionTo(S.sending, at: t1);

      expect(sending.leaseOwner, 'worker-a');
      expect(sending.leaseExpiresAt, expiry);
    });

    test('leaving the in-flight states clears the lease', () {
      final sending = buildTestOperation(id: 'op-1', status: S.sending);

      for (final next in [
        S.acknowledged,
        S.retryScheduled,
        S.conflict,
        S.rejected,
        S.pending,
      ]) {
        final result = sending.transitionTo(next, at: t1);
        expect(result.leaseOwner, isNull, reason: next.name);
        expect(result.leaseExpiresAt, isNull, reason: next.name);
      }
    });
  });
}
