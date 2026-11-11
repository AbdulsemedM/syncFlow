/// Dio REST transport for SyncFlow.
///
/// ```dart
/// final transport = DioSyncTransport(
///   dio: dio,
///   authentication: SyncAuthentication(
///     accessToken: (accountId) => auth.tokenFor(accountId),
///     refresh: (accountId) => auth.refresh(accountId),
///   ),
/// );
/// ```
library;

export 'src/dio_sync_transport.dart';
export 'src/sync_authentication.dart';
