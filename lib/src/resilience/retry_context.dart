/// Immutable snapshot of the retry state passed to context-aware predicates.
///
/// [RetryContext] gives predicates full visibility into the retry loop's
/// current state — the attempt counter, total elapsed time, and the outcome
/// (exception or result) that caused the most recent failure.
///
/// ## Usage
///
/// Receive a [RetryContext] via context-aware conditions:
///
/// ```dart
/// // Stop retrying after 30 s, regardless of attempts remaining.
/// final policy = RetryResiliencePolicy(
///   maxRetries: 10,
///   retryOnContext: (ex, ctx) {
///     if (ctx.elapsed > const Duration(seconds: 30)) return false;
///     return ex is SocketException;
///   },
/// );
/// ```
///
/// ```dart
/// // Retry only on transient status codes, but give up faster on backoff.
/// final policy = RetryResiliencePolicy(
///   maxRetries: 5,
///   retryOnResultContext: (result, ctx) {
///     if (ctx.attempt >= 3 && result is HttpResponse &&
///         result.statusCode == 503) {
///       return false; // stop after 3 attempts for 503
///     }
///     return result is HttpResponse && result.statusCode >= 500;
///   },
/// );
/// ```
final class RetryContext {
  /// Creates a [RetryContext].
  const RetryContext({
    required this.attempt,
    required this.elapsed,
    this.lastException,
    this.lastStackTrace,
    this.lastResult,
  });

  /// 1-based index of the attempt that **just** produced the failure being
  /// evaluated.
  ///
  /// * `1` — the initial attempt failed.
  /// * `2` — the first retry failed.
  /// * `n` — the (n-1)th retry failed.
  final int attempt;

  /// Total wall-clock time elapsed since the **first** attempt began.
  ///
  /// This includes all back-off delays accumulated so far.  Use this to
  /// implement deadline-aware retry conditions:
  ///
  /// ```dart
  /// retryOnContext: (_, ctx) => ctx.elapsed < const Duration(seconds: 30),
  /// ```
  final Duration elapsed;

  /// The exception thrown by the last attempt, or `null` when the failure
  /// was result-based (i.e. [lastResult] is set).
  final Object? lastException;

  /// Stack trace for [lastException], when available.
  final StackTrace? lastStackTrace;

  /// The result returned by the last attempt, or `null` when an exception was
  /// thrown.
  ///
  /// Non-null only during result-based retry evaluation
  /// (`retryOnResultContext` / `retryOnResult`).
  final dynamic lastResult;

  @override
  String toString() => 'RetryContext('
      'attempt=$attempt, '
      'elapsed=${elapsed.inMilliseconds}ms, '
      'lastException=${lastException?.runtimeType})';
}
