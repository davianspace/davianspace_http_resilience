import 'dart:convert';

import '../core/http_response.dart';
import '../exceptions/http_status_exception.dart';

/// Extension methods on [HttpResponse] for common decoding patterns.
///
/// All **synchronous** getters (`bodyAsString`, `bodyAsJson`, …) require a
/// *buffered* response (`isStreaming == false`).  They will return empty /
/// null when called on a streaming response because [body] is `null`.
///
/// When the response may be streaming, use the **async** variants instead:
/// [readAsString], [readAsJson], [readAsJsonMap], [readAsJsonList].  These
/// work for both buffered and streaming responses.
extension HttpResponseExtensions on HttpResponse {
  // -------------------------------------------------------------------------
  // Synchronous helpers — require buffered response
  // -------------------------------------------------------------------------

  /// Decodes the response body as a UTF-8 string.
  ///
  /// Returns an empty string when [body] is `null` or empty.
  ///
  /// **Requires** a buffered response (`isStreaming == false`).  Use
  /// [readAsString] for streaming responses.
  String get bodyAsString {
    final bytes = body;
    if (bytes == null || bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Parses the response body as JSON.
  ///
  /// Returns `null` when [body] is `null` or empty.
  /// Throws [FormatException] for invalid JSON.
  ///
  /// **Requires** a buffered response (`isStreaming == false`).  Use
  /// [readAsJson] for streaming responses.
  Object? get bodyAsJson {
    final s = bodyAsString;
    if (s.isEmpty) return null;
    return jsonDecode(s);
  }

  /// Parses the response body as a JSON object (`Map<String, dynamic>`).
  ///
  /// Returns `null` when [body] is `null`, empty, or does not parse as a map.
  ///
  /// **Requires** a buffered response (`isStreaming == false`).  Use
  /// [readAsJsonMap] for streaming responses.
  Map<String, dynamic>? get bodyAsJsonMap {
    final obj = bodyAsJson;
    return obj is Map<String, dynamic> ? obj : null;
  }

  /// Parses the response body as a JSON array (`List<dynamic>`).
  ///
  /// Returns `null` when [body] is `null`, empty, or does not parse as a list.
  ///
  /// **Requires** a buffered response (`isStreaming == false`).  Use
  /// [readAsJsonList] for streaming responses.
  List<dynamic>? get bodyAsJsonList {
    final obj = bodyAsJson;
    return obj is List<dynamic> ? obj : null;
  }

  // -------------------------------------------------------------------------
  // Async helpers — work with both buffered and streaming responses
  // -------------------------------------------------------------------------

  /// Reads and decodes the full response body as a UTF-8 string.
  ///
  /// Works for both buffered *and* streaming responses.  For buffered
  /// responses this is equivalent to the synchronous [bodyAsString] getter
  /// but always returns a `Future` for uniform call-sites.
  ///
  /// A streaming response's body stream is consumed once; calling this
  /// method again on the same streaming [HttpResponse] will throw.
  Future<String> readAsString() async {
    if (!isStreaming) return bodyAsString;
    final buffered = await toBuffered();
    return buffered.bodyAsString;
  }

  /// Reads and parses the full response body as JSON.
  ///
  /// Works for both buffered *and* streaming responses.
  Future<Object?> readAsJson() async {
    final s = await readAsString();
    if (s.isEmpty) return null;
    return jsonDecode(s);
  }

  /// Reads and parses the full response body as a JSON object.
  ///
  /// Returns `null` when the body is empty or does not parse as a
  /// `Map<String, dynamic>`.
  Future<Map<String, dynamic>?> readAsJsonMap() async {
    final obj = await readAsJson();
    return obj is Map<String, dynamic> ? obj : null;
  }

  /// Reads and parses the full response body as a JSON array.
  ///
  /// Returns `null` when the body is empty or does not parse as a
  /// `List<dynamic>`.
  Future<List<dynamic>?> readAsJsonList() async {
    final obj = await readAsJson();
    return obj is List<dynamic> ? obj : null;
  }

  // -------------------------------------------------------------------------
  // Guard
  // -------------------------------------------------------------------------

  /// Throws a [HttpStatusException] if [isSuccess] is `false`.
  ///
  /// Returns `this` for fluent chaining:
  /// ```dart
  /// final body = (await client.get(uri)).ensureSuccess().bodyAsJsonMap;
  /// ```
  ///
  /// Works with both buffered and streaming responses — only the status code
  /// is inspected (body bytes are not consumed).
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
