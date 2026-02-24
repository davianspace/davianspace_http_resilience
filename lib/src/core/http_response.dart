import 'package:meta/meta.dart';

/// An immutable representation of an HTTP response returned by the pipeline.
///
/// [`HttpResponse`] is constructed by the terminal [`HttpHandler`] and flows
/// back through the middleware chain unchanged unless a handler explicitly
/// transforms it.
@immutable
final class HttpResponse {
  /// Creates an immutable [`HttpResponse`].
  ///
  /// [statusCode]  — HTTP status code (e.g. 200, 404, 503).
  /// [headers]     — Response headers; defaults to an empty map.
  /// [body]        — Raw response bytes; may be `null` for HEAD/204 responses.
  /// [duration]    — Total round-trip time measured by the pipeline.
  const HttpResponse({
    required this.statusCode,
    Map<String, String>? headers,
    this.body,
    this.duration = Duration.zero,
  }) : _headers = headers ?? const {};

  /// HTTP status code.
  final int statusCode;

  final Map<String, String> _headers;

  /// Raw body bytes returned from the server, or `null`.
  final List<int>? body;

  /// Total round-trip duration as measured by the pipeline, not the server.
  final Duration duration;

  // -------------------------------------------------------------------------
  // Derived helpers
  // -------------------------------------------------------------------------

  /// Immutable view of the response headers.
  Map<String, String> get headers => Map.unmodifiable(_headers);

  /// `true` when [statusCode] is in the 2xx range (200–299).
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// `true` when [statusCode] is in the 4xx range (client errors).
  bool get isClientError => statusCode >= 400 && statusCode < 500;

  /// `true` when [statusCode] is in the 5xx range (server errors).
  bool get isServerError => statusCode >= 500 && statusCode < 600;

  /// `true` when [statusCode] is 3xx (redirect family).
  bool get isRedirect => statusCode >= 300 && statusCode < 400;

  // -------------------------------------------------------------------------
  // Named constructors for common scenarios
  // -------------------------------------------------------------------------

  /// Creates a synthetic 200-OK response — useful in tests and cache policies.
  factory HttpResponse.ok({List<int>? body, Map<String, String>? headers}) =>
      HttpResponse(statusCode: 200, body: body, headers: headers);

  /// Creates a synthetic cached response — useful in fallback policies to
  /// return stale / offline data when the primary request fails.
  ///
  /// The response body is encoded as UTF-8 code units.
  /// An `X-Cache: HIT` header is added unless overridden.
  ///
  /// ```dart
  /// final policy = FallbackPolicy(
  ///   fallbackAction: (ctx, err, st) async =>
  ///       HttpResponse.cached('offline data'),
  /// );
  /// ```
  factory HttpResponse.cached(
    String body, {
    int statusCode = 200,
    Map<String, String>? headers,
  }) =>
      HttpResponse(
        statusCode: statusCode,
        body: body.codeUnits,
        headers: {'X-Cache': 'HIT', ...?headers},
      );

  /// Creates a synthetic 503 response — useful for bulkhead / circuit-breaker
  /// failure simulations.
  factory HttpResponse.serviceUnavailable({
    Map<String, String>? headers,
  }) =>
      HttpResponse(statusCode: 503, headers: headers);

  // -------------------------------------------------------------------------
  // Copy-with
  // -------------------------------------------------------------------------

  /// Returns a shallow copy with the specified fields replaced.
  HttpResponse copyWith({
    int? statusCode,
    Map<String, String>? headers,
    List<int>? body,
    Duration? duration,
  }) =>
      HttpResponse(
        statusCode: statusCode ?? this.statusCode,
        headers: headers ?? _headers,
        body: body ?? this.body,
        duration: duration ?? this.duration,
      );

  @override
  String toString() => 'HttpResponse(status=$statusCode, success=$isSuccess, '
      'duration=${duration.inMilliseconds}ms)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HttpResponse &&
          other.statusCode == statusCode &&
          other.body == body &&
          other.duration == duration);

  @override
  int get hashCode => Object.hash(statusCode, body, duration);
}
