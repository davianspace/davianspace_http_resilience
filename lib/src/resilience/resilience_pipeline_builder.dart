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
import 'policy.dart';
import 'policy_registry.dart';
import 'resilience_policy.dart';
import 'retry_resilience_policy.dart';
import 'timeout_resilience_policy.dart';

/// A fluent builder for composing [ResiliencePolicy] instances into an ordered
/// pipeline.
///
/// [ResiliencePipelineBuilder] is an alternative to [Policy.wrap] and
/// [ResiliencePolicy.wrap] that lets you build up a pipeline method-by-method
/// before calling [build].
///
/// ## Execution order
///
/// Policies are stored **outermost-first**: the first `add*` call becomes the
/// outermost wrapper; the last `add*` call becomes the innermost one, which
/// executes immediately before the real action.
///
/// The recommended stack for HTTP calls (outermost → innermost):
///
/// ```
/// timeout         — hard upper bound on the whole operation
///   circuitBreaker — fast-fail when the service is down
///     retry        — handle transient errors within the time budget
///       action()
/// ```
///
/// ## Example
///
/// ```dart
/// final policy = ResiliencePipelineBuilder()
///     .addTimeout(const Duration(seconds: 10))
///     .addCircuitBreaker(
///         circuitName: 'payments-api',
///         failureThreshold: 5,
///         breakDuration: const Duration(seconds: 30),
///       )
///     .addRetry(
///         maxRetries: 3,
///         backoff: const ExponentialBackoff(Duration(milliseconds: 200)),
///       )
///     .build();
///
/// final response = await policy.execute(() => httpClient.get(uri));
/// ```
///
/// ## Inspection
///
/// A built pipeline is a [PolicyWrap] whose [PolicyWrap.policies] list reflects
/// the declared order:
///
/// ```dart
/// final pipeline = ResiliencePipelineBuilder()
///     .addTimeout(const Duration(seconds: 5))
///     .addRetry(maxRetries: 3)
///     .build() as PolicyWrap;
///
/// print(pipeline.policies.length);  // 2
/// print(pipeline.policies[0]);      // TimeoutResiliencePolicy(...)
/// ```
final class ResiliencePipelineBuilder {
  /// Creates an empty [ResiliencePipelineBuilder].
  ResiliencePipelineBuilder();

  final List<ResiliencePolicy> _policies = [];

  // ---------------------------------------------------------------------------
  // Generic add
  // ---------------------------------------------------------------------------

  /// Appends [policy] to the end of the current pipeline (becomes the new
  /// innermost wrapper when the chain is built).
  ///
  /// Returns `this` to allow fluent chaining.
  ResiliencePipelineBuilder addPolicy(ResiliencePolicy policy) {
    _policies.add(policy);
    return this;
  }

  // ---------------------------------------------------------------------------
  // Type-specific convenience methods
  // ---------------------------------------------------------------------------

  /// Appends a [RetryResiliencePolicy] that retries on any exception.
  ///
  /// [maxRetries]           — additional attempts after the first (0 = no retries).
  /// [backoff]              — back-off strategy; defaults to [NoBackoff].
  /// [retryForever]         — when `true`, retries indefinitely; [maxRetries] is
  ///                          ignored.
  /// [cancellationToken]    — cooperative stop signal for infinite loops.
  /// [retryOn]              — legacy exception filter.
  /// [retryOnResult]        — legacy result filter.
  /// [retryOnContext]       — context-aware exception filter (takes priority).
  /// [retryOnResultContext] — context-aware result filter (takes priority).
  ///
  /// ```dart
  /// builder.addRetry(
  ///   maxRetries: 3,
  ///   backoff: ExponentialBackoff(Duration(milliseconds: 200), useJitter: true),
  /// );
  /// ```
  ResiliencePipelineBuilder addRetry({
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
      addPolicy(
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
        ),
      );

  /// Appends a [RetryResiliencePolicy] pre-configured for HTTP (retries on
  /// exceptions **and** on the listed status codes).
  ///
  /// ```dart
  /// builder.addHttpRetry(
  ///   maxRetries: 3,
  ///   retryOnStatusCodes: [429, 500, 503],
  /// );
  /// ```
  ResiliencePipelineBuilder addHttpRetry({
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
      addPolicy(
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
        ),
      );

  /// Appends a [RetryResiliencePolicy] driven by an [OutcomeClassifier].
  ///
  /// [classifier] decides whether each outcome (response or exception) is
  /// retryable.  Defaults to [HttpOutcomeClassifier] when omitted.
  ///
  /// ```dart
  /// builder.addClassifiedRetry(
  ///   maxRetries: 3,
  ///   backoff: ExponentialBackoff(Duration(milliseconds: 200)),
  ///   classifier: ThrottleAwareClassifier(),
  /// );
  /// ```
  ResiliencePipelineBuilder addClassifiedRetry({
    required int maxRetries,
    RetryBackoff backoff = const ExponentialBackoff(
      Duration(milliseconds: 200),
    ),
    OutcomeClassifier classifier = const HttpOutcomeClassifier(),
    bool retryForever = false,
    CancellationToken? cancellationToken,
    ResilienceEventHub? eventHub,
  }) =>
      addPolicy(
        RetryResiliencePolicy(
          maxRetries: maxRetries,
          backoff: backoff,
          classifier: classifier,
          retryForever: retryForever,
          cancellationToken: cancellationToken,
          eventHub: eventHub,
        ),
      );

  /// Appends a [RetryResiliencePolicy] that retries **indefinitely** until the
  /// action succeeds, [cancellationToken] fires, or a non-retryable error is
  /// thrown.
  ///
  /// ```dart
  /// final token = CancellationToken();
  /// Future.delayed(const Duration(minutes: 1), token.cancel);
  ///
  /// builder.addRetryForever(
  ///   backoff: ExponentialBackoff(
  ///     Duration(milliseconds: 500),
  ///     maxDelay: Duration(seconds: 30),
  ///     useJitter: true,
  ///   ),
  ///   cancellationToken: token,
  /// );
  /// ```
  ResiliencePipelineBuilder addRetryForever({
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
      addPolicy(
        RetryResiliencePolicy.forever(
          backoff: backoff,
          cancellationToken: cancellationToken,
          retryOn: retryOn,
          retryOnResult: retryOnResult,
          retryOnContext: retryOnContext,
          retryOnResultContext: retryOnResultContext,
          classifier: classifier,
          eventHub: eventHub,
        ),
      );

  /// Appends a [CircuitBreakerResiliencePolicy].
  ///
  /// [circuitName]      — logical name used for diagnostics and registry
  ///                      keying.
  /// [failureThreshold] — consecutive failures before the circuit opens
  ///                      (default 5).
  /// [successThreshold] — consecutive successes in Half-Open to close the
  ///                      circuit (default 1).
  /// [breakDuration]    — how long the circuit stays open before probing
  ///                      (default 30 s).
  /// [onStateChange]    — optional state-transition callbacks.
  ///
  /// ```dart
  /// builder.addCircuitBreaker(
  ///   circuitName: 'payments-api',
  ///   failureThreshold: 5,
  ///   onStateChange: [(from, to) => log.info('CB: $from → $to')],
  /// );
  /// ```
  ResiliencePipelineBuilder addCircuitBreaker({
    required String circuitName,
    int failureThreshold = 5,
    int successThreshold = 1,
    Duration breakDuration = const Duration(seconds: 30),
    CircuitBreakerResultCondition? shouldCount,
    CircuitBreakerRegistry? registry,
    List<CircuitStateChangeCallback>? onStateChange,
    ResilienceEventHub? eventHub,
  }) =>
      addPolicy(
        CircuitBreakerResiliencePolicy(
          circuitName: circuitName,
          failureThreshold: failureThreshold,
          successThreshold: successThreshold,
          breakDuration: breakDuration,
          shouldCount: shouldCount,
          registry: registry,
          onStateChange: onStateChange,
          eventHub: eventHub,
        ),
      );

  /// Appends a [TimeoutResiliencePolicy] that cancels the action after
  /// [timeout].
  ///
  /// ```dart
  /// builder.addTimeout(const Duration(seconds: 10));
  /// ```
  ResiliencePipelineBuilder addTimeout(
    Duration timeout, {
    ResilienceEventHub? eventHub,
  }) =>
      addPolicy(TimeoutResiliencePolicy(timeout, eventHub: eventHub));

  /// Appends a [BulkheadResiliencePolicy] that limits parallel executions.
  ///
  /// ```dart
  /// builder.addBulkhead(maxConcurrency: 20, maxQueueDepth: 100);
  /// ```
  ResiliencePipelineBuilder addBulkhead({
    required int maxConcurrency,
    int maxQueueDepth = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    ResilienceEventHub? eventHub,
  }) =>
      addPolicy(
        BulkheadResiliencePolicy(
          maxConcurrency: maxConcurrency,
          maxQueueDepth: maxQueueDepth,
          queueTimeout: queueTimeout,
          eventHub: eventHub,
        ),
      );

  /// Appends a [BulkheadIsolationResiliencePolicy] that limits concurrent
  /// executions using an efficient zero-polling semaphore.
  ///
  /// [maxConcurrentRequests] — maximum simultaneous executions (≥ 1).
  /// [maxQueueSize]          — maximum queued requests (0 = reject immediately).
  /// [queueTimeout]          — max wait time before rejection.
  /// [onRejected]            — optional callback on every rejection.
  ///
  /// ```dart
  /// builder.addBulkheadIsolation(
  ///   maxConcurrentRequests: 10,
  ///   maxQueueSize: 20,
  ///   queueTimeout: Duration(seconds: 5),
  /// );
  /// ```
  ResiliencePipelineBuilder addBulkheadIsolation({
    int maxConcurrentRequests = 10,
    int maxQueueSize = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    BulkheadRejectedCallback? onRejected,
    ResilienceEventHub? eventHub,
  }) =>
      addPolicy(
        BulkheadIsolationResiliencePolicy(
          maxConcurrentRequests: maxConcurrentRequests,
          maxQueueSize: maxQueueSize,
          queueTimeout: queueTimeout,
          onRejected: onRejected,
          eventHub: eventHub,
        ),
      );

  /// Appends a [FallbackResiliencePolicy] that executes [fallbackAction] when
  /// the primary action fails or returns an unacceptable result.
  ///
  /// Place this **outermost** so it catches exhausted retries and open circuits:
  ///
  /// ```dart
  /// final policy = ResiliencePipelineBuilder()
  ///     .addFallback(
  ///       fallbackAction: (_, __) async => HttpResponse.cached('offline'),
  ///       classifier: const HttpOutcomeClassifier(),
  ///       onFallback: (ex, st) => log.warning('Fallback triggered: $ex'),
  ///     )
  ///     .addTimeout(const Duration(seconds: 10))
  ///     .addRetry(maxRetries: 3)
  ///     .build();
  /// ```
  ResiliencePipelineBuilder addFallback({
    required FallbackAction fallbackAction,
    FallbackExceptionPredicate? shouldHandle,
    FallbackResultPredicate? shouldHandleResult,
    OutcomeClassifier? classifier,
    FallbackCallback? onFallback,
    ResilienceEventHub? eventHub,
  }) =>
      addPolicy(
        FallbackResiliencePolicy(
          fallbackAction: fallbackAction,
          shouldHandle: shouldHandle,
          shouldHandleResult: shouldHandleResult,
          classifier: classifier,
          onFallback: onFallback,
          eventHub: eventHub,
        ),
      );

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// Builds the pipeline into a single [ResiliencePolicy].
  ///
  /// * If one policy was added, that policy is returned as-is.
  /// * If two or more policies were added, a [PolicyWrap] is returned.
  /// * If no policies were added, a [StateError] is thrown.
  ///
  /// The builder itself is **not** reset after calling [build]; call [clear]
  /// first if you want to reuse the builder.
  ///
  /// ```dart
  /// final pipeline = ResiliencePipelineBuilder()
  ///     .addTimeout(const Duration(seconds: 5))
  ///     .addRetry(maxRetries: 3)
  ///     .build();
  /// ```
  ResiliencePolicy build() {
    if (_policies.isEmpty) {
      throw StateError(
        'ResiliencePipelineBuilder.build() called with no policies added. '
        'Call at least one add* method before calling build().',
      );
    }
    return Policy.wrap(_policies);
  }

  // ---------------------------------------------------------------------------
  // Utility
  // ---------------------------------------------------------------------------

  /// The number of policies currently registered in the builder.
  int get length => _policies.length;

  /// Whether no policies have been added yet.
  bool get isEmpty => _policies.isEmpty;

  /// Resolves [policyName] from [registry] (or from [PolicyRegistry.instance]
  /// when [registry] is omitted) and appends the result to the pipeline.
  ///
  /// ```dart
  /// final policy = ResiliencePipelineBuilder()
  ///     .addPolicyFromRegistry('fast-timeout', registry: registry)
  ///     .addPolicyFromRegistry('payments-cb',  registry: registry)
  ///     .addPolicyFromRegistry('standard-retry', registry: registry)
  ///     .build();
  /// ```
  ///
  /// Throws [StateError] if [policyName] is not found in the registry.
  ResiliencePipelineBuilder addPolicyFromRegistry(
    String policyName, {
    PolicyRegistry? registry,
  }) =>
      addPolicy((registry ?? PolicyRegistry.instance).get(policyName));

  /// Removes all policies from the builder, resetting it to an empty state.
  ///
  /// Returns `this` to allow further `add*` calls.
  ResiliencePipelineBuilder clear() {
    _policies.clear();
    return this;
  }

  /// An unmodifiable view of the policies currently registered, in
  /// outermost-first order.
  List<ResiliencePolicy> get policies => List.unmodifiable(_policies);

  @override
  String toString() => 'ResiliencePipelineBuilder(length=$length)';
}
