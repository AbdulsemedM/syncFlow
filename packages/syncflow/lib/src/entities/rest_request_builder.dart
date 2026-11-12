import '../adapters/sync_storage.dart';
import '../models/exceptions.dart';
import '../models/sync_request.dart';
import '../queue/operation.dart';
import '../queue/operation_type.dart';
import 'sync_entity.dart';

/// Builds REST requests for operations from their registered [SyncEntity].
///
/// * The method and path come from the entity's [RestEndpoint]. `{id}` is
///   replaced by the URL-encoded entity ID.
/// * IDs are resolved through stored ID mappings: an operation queued against
///   a temporary ID is sent to the server ID once the create was acknowledged.
///   The same applies to payload fields declared in `SyncEntity.references`.
/// * Creates and updates send the payload as the body; deletes send no body.
/// * A non-null base version is sent in [baseVersionHeader] (default
///   `If-Match`), so the server can detect conflicting writes.
///
/// Throws an [UnknownEntityException] or [UnsupportedOperationTypeException]
/// for misconfigured operations, which the engine records as rejections.
///
/// Use it as the engine's request builder: `requestBuilder: builder.build`.
final class RestRequestBuilder {
  /// Creates a builder over [entities], resolving IDs through [storage].
  RestRequestBuilder({
    required this.entities,
    required SyncStorage storage,
    this.timeout,
    this.baseVersionHeader = 'If-Match',
  }) : _storage = storage;

  /// Registered entities.
  final SyncEntityRegistry entities;

  final SyncStorage _storage;

  /// Per-request timeout, or `null` for the transport default.
  final Duration? timeout;

  /// Header carrying the base version, or `null` to never send it.
  final String? baseVersionHeader;

  /// Builds the request for [operation].
  Future<SyncRequest> build(SyncOperation operation) async {
    final entity = entities.require(operation.entityName);
    final custom = entity.requestBuilder;
    if (custom != null) return custom(operation);

    final endpoint = entity.endpoint;
    final (method, template) = switch (operation.operationType) {
      SyncOperationType.create => (endpoint.createMethod, endpoint.create),
      SyncOperationType.update => (endpoint.updateMethod, endpoint.update),
      SyncOperationType.delete => (endpoint.deleteMethod, endpoint.delete),
    };
    if (template == null) {
      throw UnsupportedOperationTypeException(
        entityName: entity.name,
        operationType: operation.operationType.name,
      );
    }

    var path = template;
    if (template.contains('{id}')) {
      final id = await _resolve(
        operation.accountId,
        entity.name,
        operation.entityId,
      );
      path = template.replaceAll('{id}', Uri.encodeComponent(id));
    }

    final baseVersion = operation.baseVersion;
    return SyncRequest(
      method: method,
      path: path,
      accountId: operation.accountId,
      headers: {
        if (baseVersionHeader != null && baseVersion != null)
          baseVersionHeader!: baseVersion,
      },
      body: operation.operationType == SyncOperationType.delete
          ? null
          : await _resolveReferences(operation, entity),
      timeout: timeout,
      idempotencyKey: operation.idempotencyKey,
      operationId: operation.id,
    );
  }

  Future<Map<String, Object?>> _resolveReferences(
    SyncOperation operation,
    SyncEntity entity,
  ) async {
    final payload = Map<String, Object?>.of(operation.payload);
    for (final MapEntry(key: field, value: target)
        in entity.references.entries) {
      final value = payload[field];
      if (value is String) {
        payload[field] = await _resolve(operation.accountId, target, value);
      } else if (value is List<Object?>) {
        payload[field] = [
          for (final element in value)
            element is String
                ? await _resolve(operation.accountId, target, element)
                : element,
        ];
      }
    }
    return payload;
  }

  Future<String> _resolve(
    String accountId,
    String entityName,
    String localId,
  ) async =>
      await _storage.resolveServerId(
        accountId: accountId,
        entityName: entityName,
        localId: localId,
      ) ??
      localId;
}
