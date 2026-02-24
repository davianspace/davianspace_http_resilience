import 'dart:convert';

import '../core/http_response.dart';
import '../exceptions/http_status_exception.dart';

/// Extension methods on [HttpResponse] for common decoding patterns.
extension HttpResponseExtensions on HttpResponse {
  /// Decodes the response body as a UTF-8 string.
  ///
  /// Returns an empty string when [body] is `null` or empty.
  String get bodyAsString {
    final bytes = body;
    if (bytes == null || bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Parses the response body as JSON.
  ///
  /// Returns `null` when [body] is `null` or empty.
  /// Throws [FormatException] for invalid JSON.
  Object? get bodyAsJson {
    final s = bodyAsString;
    if (s.isEmpty) return null;
    return jsonDecode(s);
  }

  /// Parses the response body as a JSON object (`Map<String, dynamic>`).
  ///
  /// Returns `null` when [body] is `null`, empty, or does not parse as a map.
  Map<String, dynamic>? get bodyAsJsonMap {
    final obj = bodyAsJson;
    return obj is Map<String, dynamic> ? obj : null;
  }

  /// Parses the response body as a JSON array (`List<dynamic>`).
  ///
  /// Returns `null` when [body] is `null`, empty, or does not parse as a list.
  List<dynamic>? get bodyAsJsonList {
    final obj = bodyAsJson;
    return obj is List<dynamic> ? obj : null;
  }

  /// Throws a [HttpStatusException] if [isSuccess] is `false`.
  ///
  /// Returns `this` for fluent chaining:
  /// ```dart
  /// final body = (await client.get(uri)).ensureSuccess().bodyAsJsonMap;
  /// ```
  HttpResponse ensureSuccess() {
    if (!isSuccess) {
      throw HttpStatusException(
        statusCode: statusCode,
        bodyBytes: body,
      );
    }
    return this;
  }
}
