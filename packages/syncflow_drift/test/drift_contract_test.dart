import 'package:drift/native.dart';
import 'package:syncflow_drift/syncflow_drift.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

void main() {
  group('separate in-memory database', () {
    runSyncStorageContractTests(
      () => DriftSyncStorage.separate(NativeDatabase.memory()),
    );
  });

  group('shared application database', () {
    runSyncStorageContractTests(
      () => DriftSyncStorage(
        SyncFlowDatabase(NativeDatabase.memory()),
        closeDatabase: true,
      ),
    );
  });
}
