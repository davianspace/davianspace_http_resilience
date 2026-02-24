import 'package:meta/meta.dart';

import 'http_method.dart';

/// An immutable, value-type representation of an outgoing HTTP request.
///
/// Construct requests via the primary constructor or the [HttpRequest.builder]
/// factory for fluent assembly.
///
/// ```dart
/// final request = HttpRequest(
///   method: HttpMethod.get,
///   uri: Uri.parse('https://api.example.com/users/42'),
/// );
/// ```
@immutable
final class HttpRequest {
  /// Creates an immutable [HttpRequest].
  ///
  /// [method]  — required HTTP verb.
  /// [uri]     — required request target.
  /// [headers] — optional; defaults to an empty map.
  /// [body]    — optional raw-byte body.
  /// [metadata] — arbitrary key/value bag for pipeline use (e.g. policy keys).
  HttpRequest({
    required this.method,
    required this.uri,
    Map<String, String>? headers,
    this.body,
    Map<String, Object?>? metadata,
  })  : _headers = Map.unmodifiable(headers ?? const {}),
        _metadata = Map.unmodifiable(metadata ?? const {});

  /// HTTP verb for this request.
  final HttpMethod method;

  /// Full target [Uri] including scheme, host, path, and query parameters.
  final Uri uri;

  final Map<String, String> _headers;
  final Map<String, Object?> _metadata;

  /// Immutable view of the HTTP headers.
  ///
  /// The view is pre-built at construction time — repeated calls return the
  /// same object with no allocation.
  Map<String, String> get headers => _headers;

  /// Raw request body bytes, or `null` for bodyless requests (GET, HEAD, etc).
  final List<int>? body;

  /// Arbitrary metadata dictionary used by pipeline handlers and policies.
  ///
  /// Use typed extension methods (see `http_request_extensions.dart`) for
  /// well-known keys to avoid magic strings in production code.
  ///
  /// The view is pre-built at construction time — repeated calls return the
  /// same object with no allocation.
  Map<String, Object?> get metadata => _metadata;

  // -------------------------------------------------------------------------
  // Copy-with pattern (immutability helper)
  // -------------------------------------------------------------------------

  /// Returns a copy of this request with the specified fields replaced.
  HttpRequest copyWith({
    HttpMethod? method,
    Uri? uri,
    Map<String, String>? headers,
    List<int>? body,
    Map<String, Object?>? metadata,
  }) =>
      HttpRequest(
        method: method ?? this.method,
        uri: uri ?? this.uri,
        headers: headers ?? _headers,
        body: body ?? this.body,
        metadata: metadata ?? _metadata,
      );

  /// Returns a copy with the given header added or overwritten.
  HttpRequest withHeader(String name, String value) =>
      copyWith(headers: {..._headers, name: value});

  /// Returns a copy with a metadata key set.
  HttpRequest withMetadata(String key, Object? value) =>
      copyWith(metadata: {..._metadata, key: value});

  // -------------------------------------------------------------------------
  // Builder factory
  // -------------------------------------------------------------------------

  /// Convenience factory that delegates to [HttpRequestBuilder].
  ///
  /// ```dart
  /// final req = HttpRequest.builder()
  ///   ..method = HttpMethod.post
  ///   ..uri = Uri.parse('https://api.example.com/items')
  ///   ..setHeader('Content-Type', 'application/json')
  ///   ..body = utf8.encode('{"name":"widget"}')
  ///   .build();
  /// ```
  static HttpRequestBuilder builder() => HttpRequestBuilder();

  @override
  String toString() => 'HttpRequest(${method.value} $uri)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HttpRequest &&
          other.method == method &&
          other.uri == uri &&
          _headersEqual(other._headers) &&
          other.body == body);

  bool _headersEqual(Map<String, String> other) {
    if (_headers.length != other.length) return false;
    for (final entry in _headers.entries) {
      if (other[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(method, uri, _headers, body);
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// A mutable builder for constructing [HttpRequest] instances fluently.
///
/// Obtain via [HttpRequest.builder].
final class HttpRequestBuilder {
  /// The HTTP verb.  Defaults to [HttpMethod.get].
  HttpMethod method = HttpMethod.get;

  /// The target URI. **Must** be set before calling [build].
  Uri? uri;

  /// Optional raw body bytes.
  List<int>? body;

  final Map<String, String> _headers = {};
  final Map<String, Object?> _metadata = {};

  /// Adds or overwrites a header.
  void setHeader(String name, String value) => _headers[name] = value;

  /// Adds or overwrites a metadata entry.
  void setMetadata(String key, Object? value) => _metadata[key] = value;

  /// Constructs the immutable [HttpRequest].
  ///
  /// Throws [StateError] if [uri] has not been set.
  HttpRequest build() {
    if (uri == null) throw StateError('HttpRequestBuilder: uri must be set.');
    return HttpRequest(
      method: method,
      uri: uri!,
      headers: Map.unmodifiable(Map<String, String>.from(_headers)),
      body: body,
      metadata: Map.unmodifiable(Map<String, Object?>.from(_metadata)),
    );
  }
}
