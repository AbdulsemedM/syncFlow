/// Offline-first synchronization engine core.
///
/// This library is pure Dart. It defines the operation model and lifecycle,
/// the queue, and the `SyncStorage` and `SyncTransport` contracts that adapter
/// packages implement.
library;

export 'src/adapters/sync_storage.dart';
export 'src/adapters/sync_transport.dart';
export 'src/models/exceptions.dart';
export 'src/models/sync_checkpoint.dart';
export 'src/models/sync_error.dart';
export 'src/models/sync_request.dart';
export 'src/models/sync_response.dart';
export 'src/queue/operation.dart';
export 'src/queue/operation_queue.dart';
export 'src/queue/operation_status.dart';
export 'src/queue/operation_type.dart';
export 'src/queue/sync_mutation.dart';
export 'src/utils/clock.dart';
export 'src/utils/id_generator.dart';
