import 'dart:async';

/// Returns the access token for [accountId], or `null` if the account has no
/// usable credentials (for example, the user signed out).
typedef SyncAccessTokenProvider = FutureOr<String?> Function(String accountId);

/// Tries to obtain fresh credentials for [accountId] after a 401 response.
///
/// Returns `true` if new credentials are available and the request should be
/// retried once.
typedef SyncTokenRefresher = FutureOr<bool> Function(String accountId);

/// How `DioSyncTransport` authenticates requests.
///
/// SyncFlow never stores credentials. Tokens are fetched from your
/// authentication layer for the request's account on every attempt, so a
/// request is never sent with another account's token.
final class SyncAuthentication {
  /// Creates an authentication configuration.
  const SyncAuthentication({
    required this.accessToken,
    this.refresh,
    this.headerName = 'Authorization',
    this.scheme = 'Bearer',
  });

  /// Supplies the token for an account.
  final SyncAccessTokenProvider accessToken;

  /// Refreshes credentials after a 401. When `null`, a 401 is returned to the
  /// engine, which pauses the account until authentication is restored.
  final SyncTokenRefresher? refresh;

  /// Header carrying the credentials.
  final String headerName;

  /// Prefix before the token, such as `Bearer`. An empty scheme sends the
  /// token as is.
  final String scheme;

  /// The header value for [token].
  String headerValue(String token) => scheme.isEmpty ? token : '$scheme $token';
}
