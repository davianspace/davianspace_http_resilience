import '../core/cancellation_token.dart';
import '../core/http_response.dart';
import '../observability/resilience_event_hub.dart';
import '../policies/bulkhead_isolation_policy.dart';
import '../policies/circuit_breaker_policy.dart';
import 'backoff.dart';
import 'bulkhead_isolation_resilience_policy.dart';
import 'bulkhead_resilience_policy.dart';
import 'circuit_breaker_resilience_policy.dart';
import 'fallback_resilience_policy.dart';
import 'outcome_classification.dart';
import 'resilience_policy.dart';
import 'retry_resilience_policy.dart';
import 'timeout_resilience_policy.dart';

/// Static factory for constructing and composing resilience policies.
///
/// [Policy] mirrors the Polly `Policy` / `ResiliencePipeline` API surface,
/// giving a single entry-point for all policy creation.
///
/// ## Individual policies
///
/// ```dart
/// // Retry
/// Policy.retry(maxRetries: 3, backoff: ExponentialBackoff(Duration(milliseconds: 200)));
///
/// // HTTP-aware retry (also retries on 5xx status codes)
/// Policy.httpRetry(maxRetries: 3, retryOnStatusCodes: [429, 500, 503]);
///
/// // Circuit breaker
/// Policy.circuitBreaker(circuitName: 'payments', failureThreshold: 5);
///
/// // Timeout
/// Policy.timeout(Duration(seconds: 10));
///
/// // Bulkhead
/// Policy.bulkhead(maxConcurrency: 20, maxQueueDepth: 100);
/// ```
///
/// ## Composition
///
/// ```dart
/// // Fluent chaining (outermost first)
/// final policy = Policy.timeout(Duration(seconds: 5))
///     .wrap(Policy.circuitBreaker(circuitName: 'svc'))
///     .wrap(Policy.retry(maxRetries: 3));
///
/// // List-based wrapping
/// final policy = Policy.wrap([
///   Policy.timeout(Duration(seconds: 5)),
///   Policy.circuitBreaker(circuitName: 'svc'),
///   Policy.retry(maxRetries: 3),
/// ]);
///
/// final result = await policy.execute(() => makeRequest());
/// ```
abstract final class Policy {
  // ---------------------------------------------------------------------------
  // Retry
  // ---------------------------------------------------------------------------

  /// Creates a [RetryResiliencePolicy] that retries on exceptions.
  ///
  /// [maxRetries]           — additional attempts after the first (0 = no retries).
  /// [backoff]              — back-off strategy; defaults to [NoBackoff].
  /// [retryForever]         — when `true`, retries indefinitely; [maxRetries] is
  ///                          ignored.
  /// [cancellationToken]    — cooperative stop signal for infinite loops.
  /// [retryOn]              — legacy exception filter.
  /// [retryOnResult]        — legacy result filter.
  /// [retryOnContext]       — context-aware exception filter (takes priority over
  ///                          [retryOn]).
  /// [retryOnResultContext] — context-aware result filter (takes priority over
  ///                          [retryOnResult]).
  static RetryResiliencePolicy retry({
    required int maxRetries,
    RetryBackoff backoff = const NoBackoff(),
    bool retryForever = false,
    CancellationToken? cancellationToken,
    RetryCondition? retryOn,
    RetryResultCondition? retryOnResult,
    RetryContextCondition? retryOnContext,
    RetryResultContextCondition? retryOnResultContext,
    ResilienceEventHub? eventHub,
  }) =>
      RetryResiliencePolicy(
        maxRetries: maxRetries,
        backoff: backoff,
        retryForever: retryForever,
        cancellationToken: cancellationToken,
        retryOn: retryOn,
        retryOnResult: retryOnResult,
        retryOnContext: retryOnContext,
        retryOnResultContext: retryOnResultContext,
        eventHub: eventHub,
      );

  /// HTTP-aware retry — retries on exceptions **and** on configured status
  /// codes.
  ///
  /// ```dart
  /// final retry = Policy.httpRetry(
  ///   maxRetries: 3,
  ///   backoff: ExponentialBackoff(Duration(milliseconds: 200), useJitter: true),
  ///   retryOnStatusCodes: [429, 500, 503],
  /// );
  /// ```
  static RetryResiliencePolicy httpRetry({
    required int maxRetries,
    RetryBackoff backoff = const ExponentialBackoff(
      Duration(milliseconds: 200),
    ),
    List<int> retryOnStatusCodes = const [500, 502, 503, 504],
    bool retryForever = false,
    CancellationToken? cancellationToken,
    RetryContextCondition? retryOnContext,
    RetryResultContextCondition? retryOnResultContext,
    ResilienceEventHub? eventHub,
  }) =>
      RetryResiliencePolicy(
        maxRetries: maxRetries,
        backoff: backoff,
        retryForever: retryForever,
        cancellationToken: cancellationToken,
        retryOnResult: (result, _) =>
            result is HttpResponse &&
            retryOnStatusCodes.contains(result.statusCode),
        retryOnContext: retryOnContext,
        retryOnResultContext: retryOnResultContext,
        eventHub: eventHub,
      );

  /// Creates a [RetryResiliencePolicy] driven by an [OutcomeClassifier].
  ///
  /// [classifier] replaces all predicate logic — the policy retries whenever
  /// the classifier returns [OutcomeClassification.transientFailure].
  /// Defaults to [HttpOutcomeClassifier] when omitted.
  ///
  /// ```dart
  /// final policy = Policy.classifiedRetry(
  ///   maxRetries: 3,
  ///   classifier: ThrottleAwareClassifier(),
  /// );
  /// final response = await policy.execute(() => client.get(uri));
  /// ```
  static RetryResiliencePolicy classifiedRetry({
    required int maxRetries,
    RetryBackoff backoff = const ExponentialBackoff(
      Duration(milliseconds: 200),
    ),
    OutcomeClassifier classifier = const HttpOutcomeClassifier(),
    bool retryForever = false,
    CancellationToken? cancellationToken,
    ResilienceEventHub? eventHub,
  }) =>
      RetryResiliencePolicy(
        maxRetries: maxRetries,
        backoff: backoff,
        classifier: classifier,
        retryForever: retryForever,
        cancellationToken: cancellationToken,
        eventHub: eventHub,
      );

  /// Creates a [RetryResiliencePolicy] that retries **indefinitely** until the
  /// action succeeds, [cancellationToken] fires, or a non-retryable error is
  /// thrown.
  ///
  /// ```dart
  /// final token = CancellationToken();
  /// Future.delayed(const Duration(minutes: 1), token.cancel);
  ///
  /// final response = await Policy.retryForever(
  ///   backoff: ExponentialBackoff(
  ///     Duration(milliseconds: 500),
  ///     maxDelay: Duration(seconds: 30),
  ///     useJitter: true,
  ///   ),
  ///   cancellationToken: token,
  /// ).execute(() => httpClient.get(uri));
  /// ```
  static RetryResiliencePolicy retryForever({
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
      RetryResiliencePolicy.forever(
        backoff: backoff,
        cancellationToken: cancellationToken,
        retryOn: retryOn,
        retryOnResult: retryOnResult,
        retryOnContext: retryOnContext,
        retryOnResultContext: retryOnResultContext,
        classifier: classifier,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Circuit Breaker
  // ---------------------------------------------------------------------------

  /// Creates a [CircuitBreakerResiliencePolicy].
  ///
  /// ```dart
  /// final cb = Policy.circuitBreaker(
  ///   circuitName: 'inventory-api',
  ///   failureThreshold: 5,
  ///   breakDuration: Duration(seconds: 30),
  /// );
  /// ```
  static CircuitBreakerResiliencePolicy circuitBreaker({
    required String circuitName,
    int failureThreshold = 5,
    int successThreshold = 1,
    Duration breakDuration = const Duration(seconds: 30),
    CircuitBreakerResultCondition? shouldCount,
    CircuitBreakerRegistry? registry,
    List<CircuitStateChangeCallback>? onStateChange,
    ResilienceEventHub? eventHub,
  }) =>
      CircuitBreakerResiliencePolicy(
        circuitName: circuitName,
        failureThreshold: failureThreshold,
        successThreshold: successThreshold,
        breakDuration: breakDuration,
        shouldCount: shouldCount,
        registry: registry,
        onStateChange: onStateChange,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Timeout
  // ---------------------------------------------------------------------------

  /// Creates a [TimeoutResiliencePolicy] that cancels the action after
  /// [timeout].
  ///
  /// ```dart
  /// final tp = Policy.timeout(Duration(seconds: 10));
  /// ```
  static TimeoutResiliencePolicy timeout(
    Duration timeout, {
    ResilienceEventHub? eventHub,
  }) =>
      TimeoutResiliencePolicy(timeout, eventHub: eventHub);

  // ---------------------------------------------------------------------------
  // Bulkhead
  // ---------------------------------------------------------------------------

  /// Creates a [BulkheadResiliencePolicy] that limits parallel executions.
  ///
  /// ```dart
  /// final bh = Policy.bulkhead(maxConcurrency: 10, maxQueueDepth: 50);
  /// ```
  static BulkheadResiliencePolicy bulkhead({
    required int maxConcurrency,
    int maxQueueDepth = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    ResilienceEventHub? eventHub,
  }) =>
      BulkheadResiliencePolicy(
        maxConcurrency: maxConcurrency,
        maxQueueDepth: maxQueueDepth,
        queueTimeout: queueTimeout,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Bulkhead Isolation
  // ---------------------------------------------------------------------------

  /// Creates a [BulkheadIsolationResiliencePolicy] that limits concurrent
  /// executions and queues excess requests.
  ///
  /// Uses an efficient zero-polling [BulkheadIsolationSemaphore] internally.
  ///
  /// [maxConcurrentRequests] — maximum simultaneous executions (≥ 1).
  /// [maxQueueSize]          — maximum queued requests (0 = reject immediately).
  /// [queueTimeout]          — max wait time in queue before rejection.
  /// [onRejected]            — optional callback on every rejection.
  ///
  /// ```dart
  /// final policy = Policy.bulkheadIsolation(
  ///   maxConcurrentRequests: 10,
  ///   maxQueueSize: 20,
  ///   queueTimeout: Duration(seconds: 5),
  /// );
  /// ```
  static BulkheadIsolationResiliencePolicy bulkheadIsolation({
    int maxConcurrentRequests = 10,
    int maxQueueSize = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    BulkheadRejectedCallback? onRejected,
    ResilienceEventHub? eventHub,
  }) =>
      BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: maxConcurrentRequests,
        maxQueueSize: maxQueueSize,
        queueTimeout: queueTimeout,
        onRejected: onRejected,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Fallback
  // ---------------------------------------------------------------------------

  /// Creates a [FallbackResiliencePolicy] that executes [fallbackAction] when
  /// the primary action fails or returns an unacceptable result.
  ///
  /// [fallbackAction]    — executed when the primary fails.  **Must** return
  ///                       a value assignable to `T` at the call-site.
  /// [shouldHandle]      — optional exception filter; all exceptions handled
  ///                       when `null`.  Return `false` to propagate.
  /// [shouldHandleResult]— optional result filter; triggers the fallback when
  ///                       the primary *succeeds* but this returns `true`.
  /// [classifier]        — optional [OutcomeClassifier] for response-based
  ///                       fallback (e.g. 5xx triggers fallback).
  /// [onFallback]        — optional side-effect callback for logging/metrics.
  ///
  /// ```dart
  /// final policy = Policy.fallback(
  ///   fallbackAction: (ex, st) async =>
  ///       HttpResponse.cached('offline data'),
  ///   classifier: const HttpOutcomeClassifier(),
  ///   onFallback: (ex, st) => log.warning('Falling back: $ex'),
  /// );
  ///
  /// // Outermost in a composed pipeline:
  /// final pipeline = Policy.wrap([
  ///   Policy.fallback(fallbackAction: (_, __) async => cachedResponse),
  ///   Policy.timeout(const Duration(seconds: 10)),
  ///   Policy.retry(maxRetries: 3),
  /// ]);
  /// ```
  static FallbackResiliencePolicy fallback({
    required FallbackAction fallbackAction,
    FallbackExceptionPredicate? shouldHandle,
    FallbackResultPredicate? shouldHandleResult,
    OutcomeClassifier? classifier,
    FallbackCallback? onFallback,
    ResilienceEventHub? eventHub,
  }) =>
      FallbackResiliencePolicy(
        fallbackAction: fallbackAction,
        shouldHandle: shouldHandle,
        shouldHandleResult: shouldHandleResult,
        classifier: classifier,
        onFallback: onFallback,
        eventHub: eventHub,
      );

  // ---------------------------------------------------------------------------
  // Composition
  // ---------------------------------------------------------------------------

  /// Wraps [policies] from outermost (index 0) to innermost (last index) into
  /// a single [ResiliencePolicy].
  ///
  /// Execution order: `policies[0]` executes first; `policies[last]` executes
  /// immediately before the real action.
  ///
  /// ```
  /// policies[0] → policies[1] → … → policies[n-1] → action()
  /// ```
  ///
  /// **Equivalent forms** — all three produce the identical pipeline:
  ///
  /// ```dart
  /// // 1. Policy.wrap — list form
  /// final p = Policy.wrap([
  ///   Policy.timeout(const Duration(seconds: 5)),
  ///   Policy.circuitBreaker(circuitName: 'svc'),
  ///   Policy.retry(maxRetries: 3),
  /// ]);
  ///
  /// // 2. Fluent chaining
  /// final p = Policy.timeout(const Duration(seconds: 5))
  ///     .wrap(Policy.circuitBreaker(circuitName: 'svc'))
  ///     .wrap(Policy.retry(maxRetries: 3));
  ///
  /// // 3. Builder
  /// final p = ResiliencePipelineBuilder()
  ///     .addTimeout(const Duration(seconds: 5))
  ///     .addCircuitBreaker(circuitName: 'svc')
  ///     .addRetry(maxRetries: 3)
  ///     .build();
  /// ```
  ///
  /// Throws [ArgumentError] if [policies] is empty.
  /// Returns `policies[0]` unchanged when the list has exactly one entry.
  static ResiliencePolicy wrap(List<ResiliencePolicy> policies) {
    if (policies.isEmpty) {
      throw ArgumentError.value(policies, 'policies', 'must not be empty');
    }
    if (policies.length == 1) return policies[0];
    return PolicyWrap(policies);
  }
}
