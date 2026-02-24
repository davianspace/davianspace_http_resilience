import 'dart:async';

import '../core/cancellation_token.dart';
import '../core/http_response.dart';
import '../exceptions/retry_exhausted_exception.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import 'backoff.dart';
import 'outcome_classification.dart';
import 'resilience_policy.dart';
import 'retry_context.dart';

// ---------------------------------------------------------------------------
// Typedef: legacy predicates
// ---------------------------------------------------------------------------

/// A predicate that decides whether an exception warrants a retry.
///
/// [exception] is the thrown error; [attempt] is the 1-based attempt number
/// that just failed (1 = initial call, 2 = first retry, …).
///
/// For richer context (elapsed time, last result, stack trace) use the
/// context-aware [RetryContextCondition] via
/// [RetryResiliencePolicy.retryOnContext] instead.
typedef RetryCondition = bool Function(Object exception, int attempt);

/// A predicate that decides whether a successful *result* warrants a retry.
///
/// [result] is the value returned by the action (typed as `dynamic` because
/// [RetryResiliencePolicy] is constructed independently of `T`); [attempt]
/// is the 1-based attempt number that produced this result.
///
/// ### HTTP example
/// ```dart
/// retryOnResult: (result, attempt) =>
///     result is HttpResponse && result.statusCode == 503,
/// ```
///
/// For richer context use [RetryResultContextCondition] via
/// [RetryResiliencePolicy.retryOnResultContext] instead.
typedef RetryResultCondition = bool Function(dynamic result, int attempt);

// ---------------------------------------------------------------------------
// Typedef: context-aware predicates
// ---------------------------------------------------------------------------

/// Context-aware exception retry predicate.
///
/// Receives the [exception] that just occurred **and** a full [RetryContext]
/// snapshot — including elapsed time, attempt counter, and last stack trace —
/// allowing sophisticated decisions:
///
/// ```dart
/// // Retry SocketExceptions for up to 30 s.
/// retryOnContext: (ex, ctx) =>
///     ex is SocketException &&
///     ctx.elapsed < const Duration(seconds: 30),
/// ```
///
/// Takes priority over [RetryCondition] when both are set.
typedef RetryContextCondition = bool Function(
  Object exception,
  RetryContext ctx,
);

/// Context-aware result retry predicate.
///
/// Receives the [result] produced by the action **and** a full [RetryContext]
/// snapshot:
///
/// ```dart
/// // Retry 503s during the first 3 attempts only.
/// retryOnResultContext: (result, ctx) =>
///     result is HttpResponse &&
///     result.statusCode == 503 &&
///     ctx.attempt < 3,
/// ```
///
/// Takes priority over [RetryResultCondition] when both are set.
typedef RetryResultContextCondition = bool Function(
  dynamic result,
  RetryContext ctx,
);

// ---------------------------------------------------------------------------
// RetryResiliencePolicy
// ---------------------------------------------------------------------------

/// A [ResiliencePolicy] that retries a failed action up to [maxRetries] times,
/// with optional infinite-retry mode and cooperative cancellation.
///
/// [RetryResiliencePolicy] is **stateless** — every call to [execute] starts
/// a fresh attempt sequence.  Instances are therefore safe to share and reuse
/// across concurrent calls (unless [CancellationToken] state is involved).
///
/// ---
///
/// ## Basic usage
/// ```dart
/// final policy = RetryResiliencePolicy(
///   maxRetries: 3,
///   backoff: ExponentialBackoff(Duration(milliseconds: 100), useJitter: true),
/// );
///
/// final data = await policy.execute(() => httpClient.get(uri));
/// ```
///
/// ## Context-aware conditions
/// ```dart
/// final policy = RetryResiliencePolicy(
///   maxRetries: 5,
///   retryOnContext: (ex, ctx) {
///     // Give up on socket errors only after 30 s total.
///     return ex is SocketException &&
///         ctx.elapsed < const Duration(seconds: 30);
///   },
///   retryOnResultContext: (result, ctx) =>
///       result is HttpResponse &&
///       result.statusCode == 503 &&
///       ctx.attempt <= 3,
/// );
/// ```
///
/// ## Infinite retry with cancellation
/// ```dart
/// final token = CancellationToken();
///
/// final policy = RetryResiliencePolicy(
///   maxRetries: 0,           // ignored when retryForever=true
///   retryForever: true,
///   backoff: ExponentialBackoff(
///     Duration(milliseconds: 500),
///     maxDelay: Duration(seconds: 30),
///     useJitter: true,
///   ),
///   cancellationToken: token,
/// );
///
/// // Cancel after 60 s.
/// Future.delayed(const Duration(minutes: 1), token.cancel);
///
/// try {
///   final response = await policy.execute(() => httpClient.get(uri));
/// } on CancellationException {
///   log.warning('Retry loop cancelled.');
/// }
/// ```
///
/// ## HTTP-aware shortcut
/// ```dart
/// final policy = RetryResiliencePolicy.forHttp(
///   maxRetries: 3,
///   retryOnStatusCodes: [429, 500, 502, 503, 504],
/// );
/// ```
final class RetryResiliencePolicy extends ResiliencePolicy {
  /// Creates a [RetryResiliencePolicy].
  ///
  /// **Finite retry** (default): retries up to [maxRetries] times.
  /// **Infinite retry**: set `retryForever: true`; [maxRetries] is ignored.
  ///
  /// Parameters:
  ///
  /// | Parameter              | Purpose |
  /// |------------------------|---------|
  /// | [maxRetries]           | Max additional attempts after the first (ignored when [retryForever]=`true`). |
  /// | [backoff]              | Back-off strategy; defaults to [NoBackoff]. |
  /// | [retryForever]         | When `true`, retries indefinitely until success, cancellation, or a non-retryable error. |
  /// | [cancellationToken]    | Cooperative stop signal for infinite (or long-running) retry loops. |
  /// | [retryOn]              | Legacy exception filter; see [retryOnContext] for the richer variant. |
  /// | [retryOnResult]        | Legacy result filter; see [retryOnResultContext] for the richer variant. |
  /// | [retryOnContext]       | Context-aware exception filter (takes priority over [retryOn]). |
  /// | [retryOnResultContext] | Context-aware result filter (takes priority over [retryOnResult]). |
  /// | [classifier]           | [OutcomeClassifier] that overrides all predicates when non-null. |
  /// | [eventHub]             | Receives a [RetryEvent] before each retry via `scheduleMicrotask`. |
  const RetryResiliencePolicy({
    required this.maxRetries,
    this.backoff = const NoBackoff(),
    this.retryForever = false,
    this.cancellationToken,
    this.retryOn,
    this.retryOnResult,
    this.retryOnContext,
    this.retryOnResultContext,
    this.classifier,
    this.eventHub,
  }) : assert(maxRetries >= 0, 'maxRetries must be non-negative');

  // ---------------------------------------------------------------------------
  // HTTP-aware factory
  // ---------------------------------------------------------------------------

  /// Creates a policy that retries on any exception **and** on responses whose
  /// status code is contained in [retryOnStatusCodes].
  ///
  /// ```dart
  /// final policy = RetryResiliencePolicy.forHttp(
  ///   maxRetries: 3,
  ///   retryOnStatusCodes: [429, 500, 503],
  /// );
  /// ```
  factory RetryResiliencePolicy.forHttp({
    required int maxRetries,
    RetryBackoff backoff = const ExponentialBackoff(
      Duration(milliseconds: 200),
    ),
    List<int> retryOnStatusCodes = const [500, 502, 503, 504],
    ResilienceEventHub? eventHub,
  }) =>
      RetryResiliencePolicy(
        maxRetries: maxRetries,
        backoff: backoff,
        retryOnResult: (result, _) =>
            result is HttpResponse &&
            retryOnStatusCodes.contains(result.statusCode),
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Classifier-driven factory
  // ---------------------------------------------------------------------------

  /// Creates a [RetryResiliencePolicy] driven entirely by an [OutcomeClassifier].
  ///
  /// The [classifier] replaces all predicates: the policy retries whenever the
  /// classifier returns [OutcomeClassification.transientFailure].
  ///
  /// ```dart
  /// final policy = RetryResiliencePolicy.withClassifier(
  ///   maxRetries: 3,
  ///   backoff: ExponentialBackoff(Duration(milliseconds: 200)),
  ///   classifier: ThrottleAwareClassifier(),
  /// );
  /// final response = await policy.execute(() => client.get(uri));
  /// ```
  factory RetryResiliencePolicy.withClassifier({
    required int maxRetries,
    RetryBackoff backoff = const ExponentialBackoff(
      Duration(milliseconds: 200),
    ),
    OutcomeClassifier classifier = const HttpOutcomeClassifier(),
    ResilienceEventHub? eventHub,
  }) =>
      RetryResiliencePolicy(
        maxRetries: maxRetries,
        backoff: backoff,
        classifier: classifier,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Infinite-retry factory
  // ---------------------------------------------------------------------------

  /// Creates a [RetryResiliencePolicy] that retries **indefinitely** until the
  /// action succeeds, the [cancellationToken] fires, or a non-retryable error
  /// is thrown.
  ///
  /// A [CancellationToken] is strongly recommended; without one the loop can
  /// only be stopped by a non-retryable exception or by cancelling the
  /// surrounding [Future].
  ///
  /// ```dart
  /// final token = CancellationToken();
  ///
  /// final policy = RetryResiliencePolicy.forever(
  ///   backoff: ExponentialBackoff(
  ///     Duration(milliseconds: 500),
  ///     maxDelay: Duration(seconds: 30),
  ///     useJitter: true,
  ///   ),
  ///   cancellationToken: token,
  /// );
  ///
  /// Future.delayed(const Duration(minutes: 1), token.cancel);
  /// final response = await policy.execute(() => httpClient.get(uri));
  /// ```
  factory RetryResiliencePolicy.forever({
    RetryBackoff backoff = const ExponentialBackoff(
      Duration(milliseconds: 500),
      useJitter: true,
    ),
    CancellationToken? cancellationToken,
    RetryCondition? retryOn,
    RetryResultCondition? retryOnResult,
    RetryContextCondition? retryOnContext,
    RetryResultContextCondition? retryOnResultContext,
    OutcomeClassifier? classifier,
    ResilienceEventHub? eventHub,
  }) =>
      RetryResiliencePolicy(
        maxRetries: 0,
        backoff: backoff,
        retryForever: true,
        cancellationToken: cancellationToken,
        retryOn: retryOn,
        retryOnResult: retryOnResult,
        retryOnContext: retryOnContext,
        retryOnResultContext: retryOnResultContext,
        classifier: classifier,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  /// Maximum number of retry attempts after the initial call.
  ///
  /// Ignored when [retryForever] is `true`.
  final int maxRetries;

  /// Back-off strategy applied between attempts.
  final RetryBackoff backoff;

  /// When `true` the policy retries indefinitely.
  ///
  /// Use [cancellationToken] to stop the loop externally, or set a
  /// [retryOnContext] predicate that returns `false` after a deadline.
  final bool retryForever;

  /// Cooperative cancellation signal for infinite (or long-running) loops.
  ///
  /// When [CancellationToken.cancel] is called the retry loop stops at the
  /// next checkpoint (before the next attempt or during a back-off delay) and
  /// throws [CancellationException].
  final CancellationToken? cancellationToken;

  /// Optional legacy exception filter.
  ///
  /// When `null` every exception is considered retryable.
  /// Return `false` to propagate the exception without retrying.
  ///
  /// Prefer [retryOnContext] for new code — it provides elapsed time and the
  /// full exception context.  If both are set, [retryOnContext] takes priority.
  final RetryCondition? retryOn;

  /// Optional legacy result filter.
  ///
  /// When non-null and returning `true`, the action is retried even when it
  /// completed without throwing.  On the last attempt the result is returned
  /// as-is regardless of this predicate.
  ///
  /// Prefer [retryOnResultContext] for new code.  If both are set,
  /// [retryOnResultContext] takes priority.
  final RetryResultCondition? retryOnResult;

  /// Context-aware exception filter (takes priority over [retryOn]).
  ///
  /// ```dart
  /// retryOnContext: (ex, ctx) =>
  ///     ex is SocketException &&
  ///     ctx.elapsed < const Duration(seconds: 30),
  /// ```
  final RetryContextCondition? retryOnContext;

  /// Context-aware result filter (takes priority over [retryOnResult]).
  ///
  /// ```dart
  /// retryOnResultContext: (result, ctx) =>
  ///     result is HttpResponse && result.statusCode == 503 && ctx.attempt <= 3,
  /// ```
  final RetryResultContextCondition? retryOnResultContext;

  /// Optional [OutcomeClassifier] that overrides all predicates.
  ///
  /// When non-null, [OutcomeClassifier.classifyException] and
  /// [OutcomeClassifier.classifyResponse] are used instead of the predicate
  /// fields.
  final OutcomeClassifier? classifier;

  /// Optional [ResilienceEventHub] that receives a [RetryEvent] before each
  /// retry attempt.
  ///
  /// Events are dispatched via `scheduleMicrotask` and never block execution.
  final ResilienceEventHub? eventHub;

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    final totalAttempts = retryForever ? null : maxRetries + 1;
    Object? lastException;
    StackTrace? lastStackTrace;
    final stopwatch = Stopwatch()..start();

    for (var attempt = 0; retryForever || attempt < totalAttempts!; attempt++) {
      // ── Cancellation check ────────────────────────────────────────────────
      cancellationToken?.throwIfCancelled();

      // ── Back-off delay (skipped before the first attempt) ─────────────────
      if (attempt > 0) {
        final delay = backoff.delayFor(attempt);
        if (delay > Duration.zero) {
          final token = cancellationToken;
          if (token != null) {
            // Race back-off against cancellation so token fires immediately.
            await Future.any<void>([
              Future<void>.delayed(delay),
              token.onCancelled,
            ]);
            token.throwIfCancelled();
          } else {
            await Future<void>.delayed(delay);
          }
        }
      }

      // ── Build context snapshot ─────────────────────────────────────────────
      final ctx = RetryContext(
        attempt: attempt + 1,
        elapsed: stopwatch.elapsed,
        lastException: lastException,
        lastStackTrace: lastStackTrace,
      );

      // ── Execute action ─────────────────────────────────────────────────────
      try {
        final result = await action();

        // Classifier-based result check.
        final cl = classifier;
        if (cl != null) {
          final isRetryableResult =
              result is HttpResponse && cl.classifyResponse(result).isRetryable;
          if (!isRetryableResult) return result;
          // Retryable result with attempts remaining.
          if (retryForever || attempt < totalAttempts! - 1) {
            _emitRetry(attempt, totalAttempts, null, null);
            continue;
          }
          // Retries exhausted on transient result.
          lastException = result;
          break;
        }

        // Context-aware or legacy result condition.
        final shouldRetryResult =
            _evalResultCondition(result, attempt + 1, ctx);
        if (shouldRetryResult &&
            (retryForever || attempt < totalAttempts! - 1)) {
          _emitRetry(attempt, totalAttempts, null, null);
          continue;
        }

        return result;
      } catch (e, st) {
        lastException = e;
        lastStackTrace = st;

        // Classifier-based exception check.
        final cl = classifier;
        if (cl != null) {
          if (!cl.classifyException(e).isRetryable) {
            Error.throwWithStackTrace(e, st);
          }
        } else {
          // Context-aware or legacy exception condition.
          if (!_evalExceptionCondition(e, attempt + 1, ctx)) {
            Error.throwWithStackTrace(e, st);
          }
        }

        // In finite mode, stop after the last attempt.
        if (!retryForever && attempt >= totalAttempts! - 1) break;

        _emitRetry(attempt, totalAttempts, e, st);
      }
    }

    stopwatch.stop();
    throw RetryExhaustedException(
      attemptsMade: totalAttempts,
      cause: lastException,
      stackTrace: lastStackTrace,
    );
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  bool _evalExceptionCondition(
    Object exception,
    int attempt,
    RetryContext ctx,
  ) {
    final ctxCond = retryOnContext;
    if (ctxCond != null) return ctxCond(exception, ctx);
    final exCond = retryOn;
    return exCond == null || exCond(exception, attempt);
  }

  bool _evalResultCondition(dynamic result, int attempt, RetryContext ctx) {
    final ctxCond = retryOnResultContext;
    if (ctxCond != null) return ctxCond(result, ctx);
    final resCond = retryOnResult;
    if (resCond != null) return resCond(result, attempt);
    return false;
  }

  void _emitRetry(
    int attempt,
    int? totalAttempts,
    Object? exception,
    StackTrace? stackTrace,
  ) {
    final hub = eventHub;
    if (hub == null) return;
    hub.emit(
      RetryEvent(
        attemptNumber: attempt + 1,
        maxAttempts: totalAttempts, // null = infinite
        delay: backoff.delayFor(attempt + 1),
        exception: exception,
        stackTrace: stackTrace,
        source: 'RetryResiliencePolicy',
      ),
    );
  }

  @override
  String toString() {
    final mode = retryForever ? 'forever' : 'maxRetries=$maxRetries';
    return 'RetryResiliencePolicy($mode, backoff=$backoff)';
  }
}
