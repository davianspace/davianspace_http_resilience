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
  /// includes a UTF-8 decoded preview, and the [body] getter decodes them on
  /// demand so no extra `String` allocation is retained when [body] is never
  /// accessed.
  HttpStatusException({
    required this.statusCode,
    List<int>? bodyBytes,
  })  : _bodyBytes = bodyBytes,
        super(
          bodyBytes != null && bodyBytes.isNotEmpty
              ? 'HTTP $statusCode: '
                  '${utf8.decode(bodyBytes, allowMalformed: true)}'
              : 'HTTP $statusCode',
        );

  /// The HTTP status code that triggered this exception (e.g. `404`, `503`).
  final int statusCode;

  final List<int>? _bodyBytes;

  /// The response body decoded as UTF-8, or `null` when no body was present.
  ///
  /// Decoded on first access; repeated calls re-decode from the stored bytes.
  String? get body {
    final bytes = _bodyBytes;
    if (bytes == null || bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  String toString() {
    final b = body;
    return 'HttpStatusException: statusCode=$statusCode'
        '${b != null && b.isNotEmpty ? " body=$b" : ""}';
  }
}
