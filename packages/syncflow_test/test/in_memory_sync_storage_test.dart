import 'dart:convert';

import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

void main() {
  runSyncStorageContractTests(InMemorySyncStorage.new);

  group('InMemorySyncStorage', () {
    test('must be initialized before use', () async {
      final storage = InMemorySyncStorage();
      expect(() => storage.getOperation('x'), throwsStateError);
    });

    test('cannot be used after close', () async {
      final storage = InMemorySyncStorage();
      await storage.initialize();
      await storage.close();
      expect(() => storage.getOperation('x'), throwsStateError);
    });

    test('rejects payloads that cannot be persisted as JSON', () async {
      final storage = InMemorySyncStorage();
      await storage.initialize();
      final operation = buildTestOperation(
        id: 'op-1',
        payload: {'when': DateTime.utc(2026)},
      );
      await expectLater(
        storage.insertOperation(operation),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(storage.length, 0);
    });

    test('returned operations are independent snapshots', () async {
      final storage = InMemorySyncStorage();
      await storage.initialize();
      final nested = <String, Object?>{'city': 'Addis Ababa'};
      await storage.insertOperation(
        buildTestOperation(id: 'op-1', payload: {'address': nested}),
      );
      nested['city'] = 'Changed';

      final read = (await storage.getOperation('op-1'))!;
      expect(read.payload['address'], {'city': 'Addis Ababa'});
    });
  });

  group('FakeClock', () {
    test('advances only when told to', () {
      final clock = FakeClock(DateTime.utc(2026, 5, 1));
      expect(clock.now(), DateTime.utc(2026, 5, 1));
      clock.advance(const Duration(hours: 1));
      expect(clock.now(), DateTime.utc(2026, 5, 1, 1));
      expect(
        () => clock.advance(const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('SequentialIdGenerator', () {
    test('produces predictable identifiers', () {
      final ids = SequentialIdGenerator(prefix: 'op');
      expect([ids.next(), ids.next(), ids.next()], ['op-1', 'op-2', 'op-3']);
    });
  });
}
