import 'dart:convert';

import '../core/http_context.dart';
import '../core/http_method.dart';
import '../core/http_request.dart';
import '../core/http_response.dart';
import '../pipeline/http_handler.dart';

/// A high-level HTTP client powered by a pre-built [HttpHandler] pipeline.
///
/// [ResilientHttpClient] provides ergonomic `get`, `post`, `put`, `patch`,
/// and `delete` methods that construct [HttpRequest] objects, wrap them in
/// an [HttpContext], and delegate to the pipeline.
///
/// Obtain a [ResilientHttpClient] via [`HttpClientFactory`] rather than
/// constructing it directly so that lifecycle (disposal) is managed centrally.
///
/// ```dart
/// final client = HttpClientFactory.create('my-service')
///     .withBaseUri(Uri.parse('https://api.example.com'))
///     .withRetry(RetryPolicy.exponential(maxRetries: 3))
///     .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'my-service'))
///     .withLogging()
///     .build();
///
/// final response = await client.get(Uri.parse('/users/42'));
/// ```
final class ResilientHttpClient {
  /// Creates a [ResilientHttpClient] backed by [pipeline].
  ///
  /// [baseUri]         — optional base [Uri]; request URIs will be resolved
  ///                     relative to it.
  /// [defaultHeaders]  — optional headers added to every request.
  /// [onDispose]       — optional callback invoked by [dispose]; provided
  ///                     automatically by [`HttpClientBuilder`].
  ResilientHttpClient({
    required HttpHandler pipeline,
    Uri? baseUri,
    Map<String, String>? defaultHeaders,
    void Function()? onDispose,
  })  : _pipeline = pipeline,
        _baseUri = baseUri,
        _defaultHeaders = defaultHeaders ?? const {},
        _onDispose = onDispose;

  final HttpHandler _pipeline;
  final Uri? _baseUri;
  final Map<String, String> _defaultHeaders;
  final void Function()? _onDispose;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Releases resources held by this client's pipeline.
  ///
  /// Closes the underlying `http.Client` when it was created internally by
  /// the builder.  If an external client was injected (via
  /// `HttpClientBuilder.withHttpClient`), the caller retains ownership and
  /// the injected client is **not** closed.
  ///
  /// After calling [dispose], this instance must not be used again.
  void dispose() => _onDispose?.call();

  // -------------------------------------------------------------------------
  // Verb helpers
  // -------------------------------------------------------------------------

  /// Sends a GET request to [uri].
  Future<HttpResponse> get(
    Uri uri, {
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.get,
        uri,
        headers: headers,
        metadata: metadata,
      );

  /// Sends a POST request to [uri] with an optional [body].
  Future<HttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.post,
        uri,
        body: body,
        headers: headers,
        metadata: metadata,
      );

  /// Sends a PUT request to [uri] with an optional [body].
  Future<HttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.put,
        uri,
        body: body,
        headers: headers,
        metadata: metadata,
      );

  /// Sends a PATCH request to [uri] with an optional [body].
  Future<HttpResponse> patch(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.patch,
        uri,
        body: body,
        headers: headers,
        metadata: metadata,
      );

  /// Sends a DELETE request to [uri].
  Future<HttpResponse> delete(
    Uri uri, {
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.delete,
        uri,
        headers: headers,
        metadata: metadata,
      );

  /// Sends a HEAD request to [uri].
  ///
  /// HEAD is identical to GET but the server must not return a body.
  /// Useful for checking resource existence or metadata without downloading
  /// the full response body.
  Future<HttpResponse> head(
    Uri uri, {
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.head,
        uri,
        headers: headers,
        metadata: metadata,
      );

  /// Sends an OPTIONS request to [uri].
  ///
  /// OPTIONS retrieves the communication options available for the target
  /// resource (e.g. the `Allow` header listing permitted HTTP methods).
  Future<HttpResponse> options(
    Uri uri, {
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) =>
      _send(
        HttpMethod.options,
        uri,
        headers: headers,
        metadata: metadata,
      );

  /// Sends a fully constructed [HttpRequest] directly through the pipeline.
  ///
  /// Use this overload for advanced scenarios (custom verbs, streaming, etc).
  Future<HttpResponse> send(
    HttpRequest request, {
    Map<String, Object?>? metadata,
  }) {
    final ctx = HttpContext(
      request: metadata != null
          ? request.copyWith(
              metadata: {...request.metadata, ...metadata},
            )
          : request,
    );
    return _pipeline.send(ctx);
  }

  // -------------------------------------------------------------------------
  // Internal
  // -------------------------------------------------------------------------

  Future<HttpResponse> _send(
    HttpMethod method,
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? metadata,
  }) {
    final resolvedUri = _baseUri?.resolveUri(uri) ?? uri;
    final mergedHeaders = {..._defaultHeaders, ...?headers};

    List<int>? bodyBytes;
    if (body is List<int>) {
      bodyBytes = body;
    } else if (body is String) {
      bodyBytes = utf8.encode(body);
      mergedHeaders.putIfAbsent('Content-Type', () => 'application/json');
    }

    final request = HttpRequest(
      method: method,
      uri: resolvedUri,
      headers: mergedHeaders.isNotEmpty ? mergedHeaders : null,
      body: bodyBytes,
      metadata: metadata,
    );

    return send(request);
  }
}
