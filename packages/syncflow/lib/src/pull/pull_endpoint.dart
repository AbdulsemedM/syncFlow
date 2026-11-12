import 'remote_change.dart';

/// Where and how an entity's remote changes are fetched.
///
/// Requests are `GET path?cursor=<checkpoint>&limit=<pageSize>`. The cursor is
/// omitted on the first pull. Cursor semantics are the server's: it must
/// return every change after the cursor, in order, including tombstones for
/// deletions.
final class PullEndpoint {
  /// Creates a pull endpoint.
  const PullEndpoint(
    this.path, {
    this.cursorParameter = 'cursor',
    this.limitParameter = 'limit',
    this.pageSize = 100,
    this.expiredCursorStatus = 410,
    this.parse = parsePullPage,
  });

  /// Path of the change feed, for example `/customers/changes`.
  final String path;

  /// Query parameter carrying the cursor.
  final String cursorParameter;

  /// Query parameter carrying the page size, or `null` to omit it.
  final String? limitParameter;

  /// Requested page size.
  final int pageSize;

  /// Status the server uses for an expired cursor, triggering a full
  /// resynchronization.
  final int expiredCursorStatus;

  /// Parses a response into a page.
  final PullPageParser parse;
}
