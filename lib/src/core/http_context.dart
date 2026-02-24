import 'cancellation_token.dart';
import 'http_request.dart';
import 'http_response.dart';

/// Mutable execution context that flows through every [`HttpHandler`] in the
/// pipeline for a single HTTP operation.
///
/// [`HttpContext`] is the single source of truth for in-flight request state.
/// Handlers may read and write its mutable properties (e.g. response,
/// retryCount) but **must not** replace the context object itself — the
/// pipeline always operates on the same [`HttpContext`] instance per request.
final class HttpContext {
  /// Creates an [`HttpContext`] wrapping the supplied [request].
  ///
  /// [cancellationToken] — caller-supplied token; a fresh token is created if
  /// none is provided.
  /// [properties]        — optional initial property bag.
  HttpContext({
    required HttpRequest request,
    CancellationToken? cancellationToken,
    Map<String, Object?>? properties,
  })  : _request = request,
        cancellationToken = cancellationToken ?? CancellationToken(),
        _properties = properties ?? {},
        startedAt = DateTime.now(),
        _stopwatch = Stopwatch()..start();

  // -------------------------------------------------------------------------
  // Request (immutable swap via copyWith pattern)
  // -------------------------------------------------------------------------

  HttpRequest _request;

  /// The current outgoing [HttpRequest].
  ///
  /// Handlers that need to mutate the request (e.g. add auth headers) must
  /// replace it via [updateRequest].
  HttpRequest get request => _request;

  /// Replaces the current [request] with an updated copy.
  ///
  /// Use [HttpRequest.copyWith] or [HttpRequest.withHeader] to produce the
  /// new value:
  /// ```dart
  /// context.updateRequest(
  ///   context.request.withHeader('Authorization', 'Bearer $token'),
  /// );
  /// ```
  void updateRequest(HttpRequest updated) => _request = updated;

  // -------------------------------------------------------------------------
  // Response
  // -------------------------------------------------------------------------

  /// The [HttpResponse] populated by the terminal handler.
  ///
  /// `null` until the inner handler completes or a policy short-circuits.
  HttpResponse? response;

  // -------------------------------------------------------------------------
  // Retry tracking
  // -------------------------------------------------------------------------

  /// The number of retry attempts performed so far (0 on the initial try).
  int retryCount = 0;

  /// Cumulative delay introduced by retry back-off across all attempts.
  Duration totalRetryDelay = Duration.zero;

  // -------------------------------------------------------------------------
  // Timing
  // -------------------------------------------------------------------------

  /// Wall-clock time at which this context was created (pipeline entry).
  ///
  /// Uses the **local** time zone (`DateTime.now()`) for human-readable
  /// diagnostics.  For monotonic elapsed-time measurement, use [elapsed]
  /// instead.
  final DateTime startedAt;

  /// Elapsed time since [startedAt].
  ///
  /// Uses a monotonic [Stopwatch] internally — allocation-free and immune to
  /// wall-clock adjustments (DST changes, NTP corrections, etc.).
  Duration get elapsed => _stopwatch.elapsed;

  final Stopwatch _stopwatch;

  // -------------------------------------------------------------------------
  // Cancellation
  // -------------------------------------------------------------------------

  /// The [CancellationToken] associated with this operation.
  final CancellationToken cancellationToken;

  /// Shorthand for [CancellationToken.throwIfCancelled].
  void throwIfCancelled() => cancellationToken.throwIfCancelled();

  // -------------------------------------------------------------------------
  // Property bag
  // -------------------------------------------------------------------------

  final Map<String, Object?> _properties;

  /// Arbitrary, strongly-typed property bag shared across all handlers.
  ///
  /// Use namespaced keys (e.g. `'resilience.retryKey'`) to avoid collisions.
  Map<String, Object?> get properties => _properties;

  /// Retrieves a typed value from the property bag.
  ///
  /// Returns `null` if the key is absent or the stored value is not of type [T].
  T? getProperty<T>(String key) {
    final value = _properties[key];
    return value is T ? value : null;
  }

  /// Stores [value] under [key] in the property bag.
  void setProperty<T>(String key, T value) => _properties[key] = value;

  /// Removes a key from the property bag.
  void removeProperty(String key) => _properties.remove(key);

  @override
  String toString() =>
      'HttpContext(request=${request.method.value} ${request.uri}, '
      'retryCount=$retryCount, elapsed=${elapsed.inMilliseconds}ms)';
}
