import 'package:syncflow/syncflow.dart';

/// Kind of a timeline entry.
enum InspectorEventKind {
  /// A synchronization run started.
  runStarted,

  /// A synchronization run finished.
  runCompleted,

  /// Expired leases were recovered.
  leasesRecovered,

  /// The server acknowledged an operation.
  acknowledged,

  /// The server assigned an ID to an entity created locally.
  idAssigned,

  /// A transient failure; another attempt is scheduled.
  retryScheduled,

  /// The server permanently rejected an operation.
  rejected,

  /// The server reported a version conflict.
  conflicted,

  /// A conflict needs manual resolution.
  conflictDetected,

  /// A conflict was settled.
  conflictResolved,

  /// A delivery result was discarded because the lease was lost.
  leaseLost,

  /// Delivery is paused until authentication is restored.
  authenticationRequired,

  /// A page of remote changes was applied.
  remoteChangesApplied,

  /// A full resynchronization of an entity started.
  fullResyncStarted,

  /// Pulling an entity failed.
  pullFailed,

  /// A developer used an inspector action (retry, cancel, pause, ...).
  developerAction,
}

/// One entry of the inspector's event timeline.
///
/// Entries are built from engine events and never contain payloads or raw
/// response bodies: only identifiers, status codes and sanitized errors.
final class InspectorEvent {
  /// Creates an entry.
  InspectorEvent({
    required this.kind,
    required DateTime at,
    required this.summary,
    this.operationId,
    this.entityName,
    this.httpStatus,
    this.serverRequestId,
    this.error,
  }) : at = at.toUtc();

  /// Converts an engine event into a timeline entry.
  factory InspectorEvent.fromSyncEvent(SyncEvent event) => switch (event) {
        SyncRunStarted() => InspectorEvent(
            kind: InspectorEventKind.runStarted,
            at: event.at,
            summary: 'Sync run started',
          ),
        SyncRunCompleted(:final result) => InspectorEvent(
            kind: InspectorEventKind.runCompleted,
            at: event.at,
            summary: 'Sync run ${result.stopReason.name}: '
                '${result.acknowledged} acknowledged, '
                '${result.retryScheduled} retrying, ${result.failed} failed'
                '${result.pulledChanges > 0 ? ', ${result.pulledChanges} '
                    'pulled' : ''}',
          ),
        LeasesRecovered(:final count) => InspectorEvent(
            kind: InspectorEventKind.leasesRecovered,
            at: event.at,
            summary: 'Recovered $count expired lease${count == 1 ? '' : 's'}',
          ),
        OperationAcknowledged(:final operation, :final response) =>
          InspectorEvent(
            kind: InspectorEventKind.acknowledged,
            at: event.at,
            summary: 'Acknowledged ${_describe(operation)}',
            operationId: operation.id,
            entityName: operation.entityName,
            httpStatus: response.statusCode,
            serverRequestId: response.serverRequestId,
          ),
        EntityIdAssigned(:final entityName, :final localId, :final serverId) =>
          InspectorEvent(
            kind: InspectorEventKind.idAssigned,
            at: event.at,
            summary: 'Server assigned ID $serverId to $entityName/$localId',
            entityName: entityName,
          ),
        OperationRetryScheduled(:final operation) => _withError(
            InspectorEventKind.retryScheduled,
            event.at,
            'Retry scheduled for ${_describe(operation)}',
            operation,
          ),
        OperationRejected(:final operation) => _withError(
            InspectorEventKind.rejected,
            event.at,
            'Rejected ${_describe(operation)}',
            operation,
          ),
        OperationConflicted(:final operation, :final response) =>
          InspectorEvent(
            kind: InspectorEventKind.conflicted,
            at: event.at,
            summary: 'Conflict on ${_describe(operation)}',
            operationId: operation.id,
            entityName: operation.entityName,
            httpStatus: response.statusCode,
            serverRequestId: response.serverRequestId,
          ),
        ConflictDetected(:final operation) => InspectorEvent(
            kind: InspectorEventKind.conflictDetected,
            at: event.at,
            summary: 'Manual resolution needed for ${_describe(operation)}',
            operationId: operation.id,
            entityName: operation.entityName,
          ),
        ConflictResolved(:final operation, :final resolution) => InspectorEvent(
            kind: InspectorEventKind.conflictResolved,
            at: event.at,
            summary: 'Conflict resolved (${_resolutionName(resolution)}) '
                'for ${_describe(operation)}',
            operationId: operation.id,
            entityName: operation.entityName,
          ),
        OperationLeaseLost(:final operationId) => InspectorEvent(
            kind: InspectorEventKind.leaseLost,
            at: event.at,
            summary: 'Lease lost; the result was discarded',
            operationId: operationId,
          ),
        AuthenticationRequired(:final operation) => InspectorEvent(
            kind: InspectorEventKind.authenticationRequired,
            at: event.at,
            summary: 'Authentication required; delivery paused',
            operationId: operation.id,
            entityName: operation.entityName,
          ),
        RemoteChangesApplied(:final entityName, :final changes) =>
          InspectorEvent(
            kind: InspectorEventKind.remoteChangesApplied,
            at: event.at,
            summary: 'Applied $changes remote change'
                '${changes == 1 ? '' : 's'} to $entityName',
            entityName: entityName,
          ),
        FullResyncStarted(:final entityName) => InspectorEvent(
            kind: InspectorEventKind.fullResyncStarted,
            at: event.at,
            summary: 'Full resync of $entityName (cursor expired)',
            entityName: entityName,
          ),
        PullFailed(:final entityName, :final error) => InspectorEvent(
            kind: InspectorEventKind.pullFailed,
            at: event.at,
            summary: 'Pulling $entityName failed',
            entityName: entityName,
            httpStatus: error.httpStatus,
            serverRequestId: error.serverRequestId,
            error: error,
          ),
      };

  /// What happened.
  final InspectorEventKind kind;

  /// When it happened (UTC).
  final DateTime at;

  /// Human-readable, payload-free description.
  final String summary;

  /// Affected operation, if any.
  final String? operationId;

  /// Affected entity type, if any.
  final String? entityName;

  /// HTTP status of the response, if any.
  final int? httpStatus;

  /// Server request identifier, for backend log correlation.
  final String? serverRequestId;

  /// Sanitized failure, if any.
  final SyncError? error;

  /// Encodes this entry as a JSON-compatible map.
  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'at': at.toIso8601String(),
        'summary': summary,
        if (operationId != null) 'operationId': operationId,
        if (entityName != null) 'entityName': entityName,
        if (httpStatus != null) 'httpStatus': httpStatus,
        if (serverRequestId != null) 'serverRequestId': serverRequestId,
        if (error != null) 'error': error!.toJson(),
      };

  static InspectorEvent _withError(
    InspectorEventKind kind,
    DateTime at,
    String summary,
    SyncOperation operation,
  ) {
    final error = operation.lastError;
    return InspectorEvent(
      kind: kind,
      at: at,
      summary: error == null
          ? summary
          : '$summary: ${error.category.name}'
              '${error.httpStatus == null ? '' : ' (HTTP ${error.httpStatus})'}',
      operationId: operation.id,
      entityName: operation.entityName,
      httpStatus: error?.httpStatus,
      serverRequestId: error?.serverRequestId,
      error: error,
    );
  }

  static String _describe(SyncOperation operation) =>
      '${operation.operationType.name} '
      '${operation.entityName}/${operation.entityId}';

  static String _resolutionName(ConflictResolution resolution) =>
      switch (resolution) {
        UseLocal() => 'use local',
        UseRemote() => 'use remote',
        MergeResolution() => 'merge',
        RequireManualResolution() => 'manual',
      };
}
