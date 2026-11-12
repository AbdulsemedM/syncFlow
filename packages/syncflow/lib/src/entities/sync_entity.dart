import 'dart:async';

import '../conflict/conflict.dart';
import '../models/exceptions.dart';
import '../models/sync_request.dart';
import '../models/sync_response.dart';
import '../pull/pull_endpoint.dart';
import '../pull/sync_entity_adapter.dart';
import '../queue/operation.dart';

/// Extracts the server-assigned ID from a successful create response, or
/// returns `null` if the response does not carry one.
typedef ServerIdExtractor = String? Function(SyncResponse response);

/// Reads `id` from a JSON object response body (string or number).
String? serverIdFromBodyId(SyncResponse response) => switch (response.body) {
      {'id': final String id} when id.isNotEmpty => id,
      {'id': final num id} => '$id',
      _ => null,
    };

/// REST endpoints of an entity. Paths may contain `{id}`, which is replaced
/// by the URL-encoded entity ID (resolved to the server ID when known).
final class RestEndpoint {
  /// Creates an endpoint configuration. A `null` path means the operation
  /// type is not supported for this entity.
  const RestEndpoint({
    required this.create,
    this.update,
    this.delete,
    this.createMethod = SyncHttpMethod.post,
    this.updateMethod = SyncHttpMethod.patch,
    this.deleteMethod = SyncHttpMethod.delete,
  });

  /// Conventional CRUD endpoints: `POST collection`, `PATCH collection/{id}`
  /// and `DELETE collection/{id}`.
  const RestEndpoint.crud(
    String collection, {
    SyncHttpMethod updateMethod = SyncHttpMethod.patch,
  }) : this(
          create: collection,
          update: '$collection/{id}',
          delete: '$collection/{id}',
          updateMethod: updateMethod,
        );

  /// Path for creates.
  final String create;

  /// Path for updates, or `null` if updates are not supported.
  final String? update;

  /// Path for deletes, or `null` if deletes are not supported.
  final String? delete;

  /// Method for creates.
  final SyncHttpMethod createMethod;

  /// Method for updates.
  final SyncHttpMethod updateMethod;

  /// Method for deletes.
  final SyncHttpMethod deleteMethod;
}

/// A synchronized entity type and how its operations map to REST requests.
final class SyncEntity {
  /// Registers [name] with its [endpoint].
  ///
  /// [references] declares payload fields holding IDs of other entities, as
  /// `field: entityName`. Their values (a string or a list of strings) are
  /// resolved to server IDs when a request is built.
  ///
  /// [serverIdFrom] extracts the server-assigned ID from create responses
  /// (default: the `id` of a JSON body). Pass `null` if the server always
  /// accepts client-generated IDs.
  ///
  /// [requestBuilder] replaces the default request mapping entirely for this
  /// entity, for endpoints that do not follow the REST conventions.
  ///
  /// [conflictResolver] settles conflicts automatically (see
  /// [ConflictStrategy]); without one, every conflict waits for manual
  /// resolution. [remoteStateFrom] extracts the server's state from conflict
  /// responses.
  ///
  /// [pull] and [adapter] enable pull synchronization: remote changes are
  /// fetched from [pull] and applied through [adapter]. The adapter also
  /// applies the server's state when a conflict is resolved with [UseRemote].
  SyncEntity({
    required this.name,
    required this.endpoint,
    Map<String, String> references = const {},
    this.serverIdFrom = serverIdFromBodyId,
    this.requestBuilder,
    this.conflictResolver,
    this.remoteStateFrom = remoteStateFromBody,
    this.pull,
    this.adapter,
  }) : references = Map.unmodifiable(references) {
    if (pull != null && adapter == null) {
      throw ArgumentError.value(
        pull,
        'pull',
        'requires an adapter to apply remote changes',
      );
    }
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
  }

  /// Entity name used in mutations, for example `customers`.
  final String name;

  /// REST endpoints.
  final RestEndpoint endpoint;

  /// Payload fields referencing other entities: `field -> entity name`.
  final Map<String, String> references;

  /// Extracts server-assigned IDs from create responses, if any.
  final ServerIdExtractor? serverIdFrom;

  /// Custom request mapping for this entity, if any.
  final FutureOr<SyncRequest> Function(SyncOperation operation)? requestBuilder;

  /// Automatic conflict resolution, or `null` for manual resolution.
  final ConflictResolver? conflictResolver;

  /// Extracts the server's state from conflict responses.
  final RemoteStateExtractor remoteStateFrom;

  /// Where remote changes are pulled from, or `null` for push-only.
  final PullEndpoint? pull;

  /// Applies remote state to the local database, if configured.
  final SyncEntityAdapter? adapter;
}

/// The set of registered entities.
final class SyncEntityRegistry {
  /// Creates a registry containing [entities].
  SyncEntityRegistry([Iterable<SyncEntity> entities = const []]) {
    entities.forEach(register);
  }

  final Map<String, SyncEntity> _entities = {};

  /// Registers [entity]. Throws an [ArgumentError] if its name is taken.
  void register(SyncEntity entity) {
    if (_entities.containsKey(entity.name)) {
      throw ArgumentError.value(
        entity.name,
        'entity',
        'is already registered',
      );
    }
    _entities[entity.name] = entity;
  }

  /// The entity named [name], or `null`.
  SyncEntity? operator [](String name) => _entities[name];

  /// The entity named [name]. Throws an [UnknownEntityException] if missing.
  SyncEntity require(String name) =>
      _entities[name] ?? (throw UnknownEntityException(name));

  /// Names of all registered entities.
  Iterable<String> get names => _entities.keys;
}
