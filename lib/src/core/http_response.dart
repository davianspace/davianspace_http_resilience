import 'dart:async';

/// An immutable representation of an HTTP response returned by the pipeline.
///
/// [`HttpResponse`] is constructed by the terminal [`HttpHandler`] and flows
/// back through the middleware chain unchanged unless a handler explicitly
/// transforms it.
///
/// ### Buffered vs. streaming mode
///
/// By default responses are *buffered*: the body is available as
/// `List<int>? body` immediately after `send` completes.
///
/// When the pipeline is configured with `HttpClientBuilder.withStreamingMode()`
/// (or a `TerminalHandler(streamingMode: true)` is used directly), the response
/// carries a *lazy stream* instead.  Callers read it via [bodyStream] and must
/// consume it exactly once.  To convert back to a fully-buffered response, call
/// [toBuffered()].
///
/// A handler that **needs** the body bytes (e.g. to decide whether to retry)
/// must call `await response.toBuffered()` before inspecting [body].
///
/// ```dart
/// // Read a large response body without buffering it entirely in memory:
/// final response = await client.get(Uri.parse('/large-file'));
/// await response.bodyStream.pipe(fileSink);
///
/// // Or convert to buffered when you need random access:
/// final buffered = await response.toBuffered();
/// print(utf8.decode(buffered.body!));
/// ```
final class HttpResponse {
  /// Creates a fully-buffered [`HttpResponse`].
  ///
  /// [statusCode]  — HTTP status code (e.g. 200, 404, 503).
  /// [headers]     — Response headers; defaults to an empty map.
  /// [body]        — Raw response bytes; may be `null` for HEAD/204 responses.
  /// [duration]    — Total round-trip time measured by the pipeline.
  HttpResponse({
    required this.statusCode,
    Map<String, String>? headers,
    this.body,
    this.duration = Duration.zero,
  })  : _headers = headers ?? const {},
        _bodyStream = null;

  /// Creates a *streaming* [`HttpResponse`].
  ///
  /// [bodyStream] carries the response body as a `Stream<List<int>>`.  The
  /// stream must be consumed exactly once.  [body] will be `null` until
  /// [toBuffered()] is called.
  ///
  /// The [duration] reflects the time-to-first-byte (TTFB) as measured by the
  /// terminal handler, NOT the full content-transfer duration.
  HttpResponse.streaming({
    required this.statusCode,
    required Stream<List<int>> bodyStream,
    Map<String, String>? headers,
    this.duration = Duration.zero,
  })  : _headers = headers ?? const {},
        body = null,
        _bodyStream = bodyStream;

  /// HTTP status code.
  final int statusCode;

  final Map<String, String> _headers;

  /// Raw body bytes returned from the server, or `null`.
  ///
  /// Will be `null` when [isStreaming] is `true` — call [toBuffered()] first,
  /// or iterate [bodyStream] directly.
  final List<int>? body;

  /// Total round-trip / time-to-first-byte duration as measured by the pipeline.
  final Duration duration;

  final Stream<List<int>>? _bodyStream;

  /// Tracks whether the streaming body has already been accessed.
  bool _streamConsumed = false;

  // -------------------------------------------------------------------------
  // Streaming helpers
  // -------------------------------------------------------------------------

  /// `true` when this response carries a lazy body stream.
  ///
  /// Call [toBuffered()] or consume [bodyStream] to access the body.
  bool get isStreaming => _bodyStream != null;

  /// The body as a `Stream<List<int>>`.
  ///
  /// Regardless of whether the response [isStreaming], this getter always
  /// returns a valid stream:
  /// - If [isStreaming] is `true`, returns the underlying live stream — consume
  ///   it **exactly once**.
  /// - If [isStreaming] is `false`, wraps [body] (or an empty list) in a
  ///   single-element stream for uniform handling.
  ///
  /// Throws [StateError] if the streaming body has already been consumed
  /// via a previous call to [bodyStream] or [toBuffered()].
  Stream<List<int>> get bodyStream {
    if (_bodyStream != null) {
      if (_streamConsumed) {
        throw StateError(
          'The streaming body has already been consumed. '
          'A streaming HttpResponse can only be read once.',
        );
      }
      _streamConsumed = true;
    }
    return _bodyStream ?? Stream<List<int>>.value(body ?? const []);
  }

  /// Materialises a streaming response into a buffered one.
  ///
  /// If [isStreaming] is `false`, returns `this` immediately (no allocation).
  /// If [isStreaming] is `true`, drains [bodyStream] into a `List<int>` and
  /// returns a new buffered [HttpResponse] with identical metadata.
  ///
  /// ```dart
  /// final buffered = await response.toBuffered();
  /// final text = utf8.decode(buffered.body ?? const []);
  /// ```
  Future<HttpResponse> toBuffered() async {
    if (!isStreaming) return this;
    if (_streamConsumed) {
      throw StateError(
        'The streaming body has already been consumed. '
        'A streaming HttpResponse can only be read once.',
      );
    }
    _streamConsumed = true;
    final chunks = <List<int>>[];
    await for (final chunk in _bodyStream!) {
      chunks.add(chunk);
    }
    final bytes = chunks.fold<List<int>>(
      [],
      (acc, chunk) => acc..addAll(chunk),
    );
    return HttpResponse(
      statusCode: statusCode,
      headers: _headers,
      body: bytes,
      duration: duration,
    );
  }

  // -------------------------------------------------------------------------
  // Derived helpers
  // -------------------------------------------------------------------------

  /// Immutable view of the response headers.
  ///
  /// The view is cached on first access — repeated calls return the same
  /// object with no allocation.
  Map<String, String> get headers =>
      _cachedHeaders ??= Map.unmodifiable(_headers);

  Map<String, String>? _cachedHeaders;

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
  ///
  /// Calling `copyWith` on a *streaming* response produces a **buffered**
  /// copy — the stream is not transferred.  Call [toBuffered()] first if you
  /// need to carry the streamed bytes through.
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
  String toString() {
    final bodyDesc = isStreaming ? 'streaming' : '${body?.length ?? 0}B';
    return 'HttpResponse(status=$statusCode, success=$isSuccess, '
        'body=$bodyDesc, duration=${duration.inMilliseconds}ms)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HttpResponse &&
          other.statusCode == statusCode &&
          other.body == body &&
          other._bodyStream == _bodyStream &&
          other.duration == duration);

  @override
  int get hashCode => Object.hash(statusCode, body, _bodyStream, duration);
}
