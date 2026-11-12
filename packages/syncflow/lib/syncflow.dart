/// Offline-first synchronization engine core.
///
/// This library is pure Dart. It defines the operation model and lifecycle,
/// the queue, and the `SyncStorage` and `SyncTransport` contracts that adapter
/// packages implement.
library;

export 'src/adapters/sync_storage.dart';
export 'src/adapters/sync_transport.dart';
export 'src/conflict/conflict.dart';
export 'src/engine/sync_engine.dart';
export 'src/engine/sync_run_result.dart';
export 'src/entities/rest_request_builder.dart';
export 'src/entities/sync_entity.dart';
export 'src/events/sync_event.dart';
export 'src/executor/delivery_outcome.dart';
export 'src/executor/operation_executor.dart'
    show ExecutionResult, SyncRequestBuilder;
export 'src/executor/response_classifier.dart';
export 'src/models/exceptions.dart';
export 'src/models/sync_checkpoint.dart';
export 'src/models/sync_error.dart';
export 'src/models/sync_id_mapping.dart';
export 'src/models/sync_request.dart';
export 'src/models/sync_response.dart';
export 'src/pull/pull_endpoint.dart';
export 'src/pull/remote_change.dart';
export 'src/pull/sync_entity_adapter.dart';
export 'src/queue/operation.dart';
export 'src/queue/operation_queue.dart';
export 'src/queue/operation_status.dart';
export 'src/queue/operation_type.dart';
export 'src/queue/sync_mutation.dart';
export 'src/scheduler/retry_policy.dart';
export 'src/utils/clock.dart';
export 'src/utils/id_generator.dart';
export 'src/utils/retry_after.dart';
