import 'dart:convert';

import 'http_resilience_exception.dart';

/// Thrown by `HttpResponseExtensions.ensureSuccess()` when the response
/// indicates an unsuccessful HTTP status code.
///
/// Extends [HttpResilienceException] so callers can catch the entire
/// resilience-error family with a single `on HttpResilienceException` clause:
///
/// ```dart
/// try {
///   final response = await client.get(uri);
///   response.ensureSuccess();
/// } on HttpResilienceException catch (e) {
///   // catches HttpStatusException, RetryExhaustedException, etc.
///   log.warning('Resilience error: $e');
/// }
/// ```
///
/// To handle only status errors:
///
/// ```dart
/// } on HttpStatusException catch (e) {
///   if (e.statusCode == 404) return null;
///   rethrow;
/// }
/// ```
final class HttpStatusException extends HttpResilienceException {
  /// Creates an [HttpStatusException] for [statusCode].
  ///
  /// [bodyBytes] — raw response body bytes.  The human-readable [message]
  /// includes a truncated UTF-8 decoded preview (up to 512 characters), and
  /// the [body] getter decodes the full bytes on demand so no extra `String`
  /// allocation is retained when [body] is never accessed.
  HttpStatusException({
    required this.statusCode,
    List<int>? bodyBytes,
  })  : _bodyBytes = bodyBytes,
        super(
          bodyBytes != null && bodyBytes.isNotEmpty
              ? 'HTTP $statusCode: '
                  '${_truncate(utf8.decode(bodyBytes, allowMalformed: true), 512)}'
              : 'HTTP $statusCode',
        );

  /// The HTTP status code that triggered this exception (e.g. `404`, `503`).
  final int statusCode;

  final List<int>? _bodyBytes;

  String? _cachedBody;

  /// Maximum number of bytes decoded by [body].
  ///
  /// Bodies larger than this are truncated to prevent unbounded memory
  /// allocation when an error response carries an unexpectedly large payload.
  static const int maxBodyBytes = 64 * 1024; // 64 KB

  /// The response body decoded as UTF-8, or `null` when no body was present.
  ///
  /// Decoded on first access; repeated calls return the cached result.
  /// Bodies larger than [maxBodyBytes] are truncated.
  String? get body {
    if (_cachedBody != null) return _cachedBody;
    final bytes = _bodyBytes;
    if (bytes == null || bytes.isEmpty) return null;
    if (bytes.length <= maxBodyBytes) {
      return _cachedBody = utf8.decode(bytes, allowMalformed: true);
    }
    final truncated = utf8.decode(
      bytes.sublist(0, maxBodyBytes),
      allowMalformed: true,
    );
    return _cachedBody =
        '$truncated\u2026 [truncated ${bytes.length - maxBodyBytes} bytes]';
  }

  /// Truncates [s] to [maxLength] characters, appending '…' if truncated.
  static String _truncate(String s, int maxLength) {
    if (s.length <= maxLength) return s;
    return '${s.substring(0, maxLength)}…';
  }

  @override
  String toString() {
    final b = body;
    return 'HttpStatusException: statusCode=$statusCode'
        '${b != null && b.isNotEmpty ? " body=$b" : ""}';
  }
}
