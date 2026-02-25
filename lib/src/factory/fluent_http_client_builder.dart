import 'package:davianspace_logging/davianspace_logging.dart' show Logger;
import 'package:http/http.dart' as http;

import '../core/cancellation_token.dart';
import '../core/http_response.dart';
import '../exceptions/bulkhead_rejected_exception.dart';
import '../exceptions/http_timeout_exception.dart';
import '../handlers/logging_handler.dart';
import '../handlers/policy_handler.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/bulkhead_isolation_policy.dart';
import '../policies/circuit_breaker_policy.dart';
import '../policies/hedging_policy.dart';
import '../resilience/backoff.dart';
import '../resilience/bulkhead_isolation_resilience_policy.dart';
import '../resilience/bulkhead_resilience_policy.dart';
import '../resilience/circuit_breaker_resilience_policy.dart';
import '../resilience/fallback_resilience_policy.dart';
import '../resilience/outcome_classification.dart';
import '../resilience/policy_registry.dart';
import '../resilience/resilience_pipeline_builder.dart';
import '../resilience/resilience_policy.dart';
import '../resilience/retry_resilience_policy.dart';
import '../resilience/timeout_resilience_policy.dart';
import 'http_client_factory.dart';
import 'resilient_http_client.dart';

// ---------------------------------------------------------------------------
// Internal typedef
// ---------------------------------------------------------------------------

/// A single configuration step applied to an [HttpClientBuilder].
///
/// Steps are stored as closures so that each [FluentHttpClientBuilder] instance
/// remains a pure value object; mutation always produces a new instance.
typedef _BuildStep = void Function(HttpClientBuilder builder);

// ============================================================================
// FluentHttpClientBuilder
// ============================================================================

/// An **immutable**, **lazy** fluent DSL for configuring [ResilientHttpClient]
/// instances with resilience policies.
///
/// Every `add*` / `with*` method returns a **new** [FluentHttpClientBuilder]
/// instance — the original is unchanged — making the builder safe to fork,
/// reuse, and share as a value object.
///
/// The actual [HttpClientBuilder] is constructed only when [build] or [done]
/// is called (lazy pipeline construction).
///
/// ---
///
/// ## Standalone use
///
/// ```dart
/// final client = FluentHttpClientBuilder('catalog')
///     .withBaseUri(Uri.parse('https://catalog.svc/v2'))
///     .withDefaultHeader('Accept', 'application/json')
///     .withLogging()
///     .addRetryPolicy(
///         maxRetries: 3,
///         backoff: ExponentialBackoff(Duration(milliseconds: 200), useJitter: true),
///       )
///     .addTimeout(Duration(seconds: 10))
///     .addCircuitBreakerPolicy(circuitName: 'catalog-api', failureThreshold: 5)
///     .build();
///
/// final response = await client.get(Uri.parse('/products'));
/// ```
///
/// ---
///
/// ## Factory-integrated use
///
/// Obtain a builder that is pre-bound to an [HttpClientFactory] via
/// [HttpClientFactoryFluentExtension.forClient].  Call [done] at the end of
/// the chain to register the configuration lazily and return the factory for
/// further method chaining:
///
/// ```dart
/// final factory = HttpClientFactory()
///   ..forClient('catalog')
///       .withBaseUri(Uri.parse('https://catalog.svc/v2'))
///       .addRetryPolicy(maxRetries: 3)
///       .addTimeout(Duration(seconds: 10))
///       .addFallbackPolicy(
///           fallbackAction: (ex, st) async =>
///               HttpResponse(statusCode: 200, body: 'cached'.codeUnits),
///         )
///       .addBulkheadPolicy(maxConcurrency: 20)
///       .done()
///   ..forClient('payments')
///       .withBaseUri(Uri.parse('https://payments.internal/v1'))
///       .addHttpRetryPolicy(maxRetries: 2)
///       .done();
///
/// final client = factory.createClient('catalog');
/// ```
///
/// ---
///
/// ## Immutability and forking
///
/// Because every mutation returns a new instance you can create a shared base
/// configuration and specialise it per client without interference:
///
/// ```dart
/// final base = FluentHttpClientBuilder()
///     .withDefaultHeader('Accept', 'application/json')
///     .withLogging()
///     .addTimeout(const Duration(seconds: 10));
///
/// final catalogClient = base
///     .withBaseUri(Uri.parse('https://catalog.svc/v2'))
///     .addRetryPolicy(maxRetries: 3)
///     .build();
///
/// final paymentsClient = base
///     .withBaseUri(Uri.parse('https://payments.internal/v1'))
///     .addRetryPolicy(maxRetries: 1)
///     .addCircuitBreakerPolicy(circuitName: 'payments-api')
///     .build();
///
/// // base is unchanged — it still has only withLogging + addTimeout.
/// ```
///
/// ---
///
/// ## Policy order (outermost → innermost)
///
/// The recommended order mirrors [ResiliencePipelineBuilder]:
///
/// ```
/// addFallbackPolicy   — outermost: catches exhausted retries / open circuits
///   withLogging       — measures full round-trip
///     addRetryPolicy  — retries transient errors
///       addCircuitBreakerPolicy — fast-fail when service is down
///         addTimeout  — per-attempt deadline
///           addBulkheadPolicy — max-concurrency cap
/// ```
final class FluentHttpClientBuilder {
  // --------------------------------------------------------------------------
  // Constructors
  // --------------------------------------------------------------------------

  /// Creates a standalone (unbound) [FluentHttpClientBuilder] with an optional
  /// diagnostic [name].
  ///
  /// Call [build] to immediately get a [ResilientHttpClient].  Use
  /// [HttpClientFactoryFluentExtension.forClient] instead to get a
  /// factory-bound builder.
  FluentHttpClientBuilder([String name = ''])
      : _name = name,
        _steps = const [],
        _baseUri = null,
        _headers = const {},
        _httpClient = null,
        _factory = null;

  /// Internal constructor used by every mutation method.
  const FluentHttpClientBuilder._({
    required String name,
    required List<_BuildStep> steps,
    required Map<String, String> headers,
    Uri? baseUri,
    http.Client? httpClient,
    HttpClientFactory? factory,
  })  : _name = name,
        _steps = steps,
        _baseUri = baseUri,
        _headers = headers,
        _httpClient = httpClient,
        _factory = factory;

  // --------------------------------------------------------------------------
  // Internal state
  // --------------------------------------------------------------------------

  final String _name;
  final List<_BuildStep> _steps;
  final Uri? _baseUri;
  final Map<String, String> _headers;
  final http.Client? _httpClient;

  /// Non-null when this builder was obtained from
  /// [HttpClientFactoryFluentExtension.forClient].
  final HttpClientFactory? _factory;

  // --------------------------------------------------------------------------
  // Internal helpers
  // --------------------------------------------------------------------------

  /// Returns a new [FluentHttpClientBuilder] with [step] appended.
  FluentHttpClientBuilder _addStep(_BuildStep step) =>
      FluentHttpClientBuilder._(
        name: _name,
        steps: [..._steps, step],
        headers: _headers,
        baseUri: _baseUri,
        httpClient: _httpClient,
        factory: _factory,
      );

  // ==========================================================================
  // Transport / infrastructure configuration
  // ==========================================================================

  /// Sets the base [Uri] used to resolve relative request URIs.
  ///
  /// When set, every HTTP verb call resolves its [Uri] argument against this
  /// base using [Uri.resolveUri].
  ///
  /// ```dart
  /// builder.withBaseUri(Uri.parse('https://api.example.com/v2'))
  /// ```
  FluentHttpClientBuilder withBaseUri(Uri baseUri) => FluentHttpClientBuilder._(
        name: _name,
        steps: _steps,
        headers: _headers,
        baseUri: baseUri,
        httpClient: _httpClient,
        factory: _factory,
      );

  /// Adds a header that is merged into every outgoing request.
  ///
  /// Per-request headers take precedence over default headers.
  ///
  /// ```dart
  /// builder
  ///     .withDefaultHeader('Accept', 'application/json')
  ///     .withDefaultHeader('X-Client-Version', '1.0.0')
  /// ```
  FluentHttpClientBuilder withDefaultHeader(String name, String value) =>
      FluentHttpClientBuilder._(
        name: _name,
        steps: _steps,
        headers: {..._headers, name: value},
        baseUri: _baseUri,
        httpClient: _httpClient,
        factory: _factory,
      );

  /// Overrides the underlying [http.Client] (useful for testing with mocks).
  ///
  /// ```dart
  /// import 'package:http/testing.dart';
  ///
  /// final builder = FluentHttpClientBuilder()
  ///     .withHttpClient(MockClient((req) async => http.Response('OK', 200)));
  /// ```
  FluentHttpClientBuilder withHttpClient(http.Client client) =>
      FluentHttpClientBuilder._(
        name: _name,
        steps: _steps,
        headers: _headers,
        baseUri: _baseUri,
        httpClient: client,
        factory: _factory,
      );

  // ==========================================================================
  // Observability
  // ==========================================================================

  /// Adds a [LoggingHandler] at the current pipeline position.
  ///
  /// Place this **outermost** so it captures the full round-trip duration,
  /// including all retry attempts.
  ///
  /// Requires a [LoggingHandler] import through the public API barrel.
  ///
  /// ```dart
  /// builder.withLogging()
  /// ```
  FluentHttpClientBuilder withLogging({Logger? logger}) =>
      _addStep((b) => b.withLogging(logger: logger));

  /// Enables streaming mode: responses are returned without buffering the
  /// body.  See [HttpClientBuilder.withStreamingMode] for full semantics.
  FluentHttpClientBuilder withStreamingMode() =>
      _addStep((b) => b.withStreamingMode());

  /// Adds a `HedgingHandler` driven by [policy].
  ///
  /// Fires speculative concurrent requests to cut tail latency. See
  /// [HttpClientBuilder.withHedging] for placement guidance and
  /// idempotency requirements.
  ///
  /// ```dart
  /// builder.withHedging(HedgingPolicy(
  ///   hedgeAfter: Duration(milliseconds: 200),
  ///   maxHedgedAttempts: 1,
  /// ))
  /// ```
  FluentHttpClientBuilder withHedging(HedgingPolicy policy) =>
      _addStep((b) => b.withHedging(policy));

  // ==========================================================================
  // Retry policies
  // ==========================================================================

  /// Appends a [RetryResiliencePolicy] (via [PolicyHandler]) that retries on
  /// any exception.
  ///
  ///
  /// [maxRetries]           — additional attempts after the first (0 = no extra
  ///                          retries, so the action runs exactly once).
  /// [backoff]              — back-off strategy; defaults to [NoBackoff] (no
  ///                          delay between retries).
  /// [retryForever]         — when `true`, retries indefinitely;
  ///                          [maxRetries] is ignored.
  /// `cancellationToken`    — cooperative stop signal for infinite-retry loops.
  /// [retryOn]              — exception filter (all exceptions retried when
  ///                          `null`).
  /// [retryOnResult]        — result filter (no result-based retries when
  ///                          `null`).
  /// [retryOnContext]       — context-aware exception filter; takes priority
  ///                          over [retryOn] when both are set.
  /// [retryOnResultContext] — context-aware result filter; takes priority over
  ///                          [retryOnResult] when both are set.
  /// [eventHub]             — optional hub for [RetryEvent] notifications.
  ///
  /// ```dart
  /// builder.addRetryPolicy(
  ///   maxRetries: 3,
  ///   backoff: ExponentialBackoff(Duration(milliseconds: 200), useJitter: true),
  /// )
  /// ```
  FluentHttpClientBuilder addRetryPolicy({
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
      _addStep(
        (b) => b.withPolicy(
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
        ),
      );

  /// Appends a [RetryResiliencePolicy] pre-configured for HTTP responses (via
  /// [PolicyHandler]) that also retries on specific HTTP status codes.
  ///
  /// In addition to all exceptions, it retries when the response status code
  /// is contained in [retryOnStatusCodes] (default: `[500, 502, 503, 504]`).
  ///
  /// ```dart
  /// builder.addHttpRetryPolicy(
  ///   maxRetries: 3,
  ///   retryOnStatusCodes: [429, 500, 503],
  ///   backoff: ExponentialBackoff(Duration(milliseconds: 200), useJitter: true),
  /// )
  /// ```
  FluentHttpClientBuilder addHttpRetryPolicy({
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
      _addStep(
        (b) => b.withPolicy(
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
        ),
      );

  /// Appends a [RetryResiliencePolicy] that retries **indefinitely** (via
  /// [PolicyHandler]) until the action succeeds, the cancellation token fires,
  /// or a non-retryable error is thrown.
  ///
  /// ```dart
  /// final token = CancellationToken();
  /// Future.delayed(const Duration(minutes: 5), token.cancel);
  ///
  /// builder.addRetryForeverPolicy(
  ///   backoff: ExponentialBackoff(
  ///     Duration(milliseconds: 500),
  ///     maxDelay: Duration(seconds: 30),
  ///     useJitter: true,
  ///   ),
  ///   cancellationToken: token,
  /// )
  /// ```
  FluentHttpClientBuilder addRetryForeverPolicy({
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
      _addStep(
        (b) => b.withPolicy(
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
        ),
      );

  // ==========================================================================
  // Timeout policy
  // ==========================================================================

  /// Appends a [TimeoutResiliencePolicy] (via [PolicyHandler]) that cancels
  /// the inner pipeline after [timeout].
  ///
  /// When placed **inside** a retry, each attempt gets its own deadline.
  /// When placed **outside** a retry, the budget is shared across all attempts.
  ///
  /// Throws [HttpTimeoutException] on expiry.
  ///
  ///
  /// ```dart
  /// builder.addTimeout(const Duration(seconds: 10))
  /// ```
  FluentHttpClientBuilder addTimeout(
    Duration timeout, {
    ResilienceEventHub? eventHub,
  }) =>
      _addStep(
        (b) =>
            b.withPolicy(TimeoutResiliencePolicy(timeout, eventHub: eventHub)),
      );

  // ==========================================================================
  // Circuit breaker policy
  // ==========================================================================

  /// Appends a [CircuitBreakerResiliencePolicy] (via [PolicyHandler]).
  ///
  /// The circuit transitions: **Closed** → **Open** (after [failureThreshold]
  /// consecutive failures) → **Half-Open** (probe after [breakDuration]) →
  /// **Closed** (on [successThreshold] consecutive successes).
  ///
  /// [circuitName]      — logical name; used for diagnostics and shared-state
  ///                      keying in [registry].
  /// [failureThreshold] — consecutive failures before the circuit opens
  ///                      (default 5).
  /// [successThreshold] — successes in Half-Open before closing (default 1).
  /// [breakDuration]    — open-state duration before probing (default 30 s).
  /// [shouldCount]      — custom predicate for counting failures; defaults to
  ///                      all exceptions and 5xx [HttpResponse] values.
  /// [registry]         — optional isolated registry; defaults to the
  ///                      process-wide singleton.
  /// [onStateChange]    — optional callbacks fired on every state transition.
  /// [eventHub]         — optional hub for [CircuitOpenEvent] /
  ///                      [CircuitCloseEvent] notifications.
  ///
  /// ```dart
  /// builder.addCircuitBreakerPolicy(
  ///   circuitName: 'catalog-api',
  ///   failureThreshold: 5,
  ///   breakDuration: Duration(seconds: 30),
  /// )
  /// ```
  FluentHttpClientBuilder addCircuitBreakerPolicy({
    required String circuitName,
    int failureThreshold = 5,
    int successThreshold = 1,
    Duration breakDuration = const Duration(seconds: 30),
    CircuitBreakerResultCondition? shouldCount,
    CircuitBreakerRegistry? registry,
    List<CircuitStateChangeCallback>? onStateChange,
    ResilienceEventHub? eventHub,
  }) =>
      _addStep(
        (b) => b.withPolicy(
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
        ),
      );

  // ==========================================================================
  // Fallback policy
  // ==========================================================================

  /// Appends a [FallbackResiliencePolicy] (via [PolicyHandler]) that executes
  /// `fallbackAction` when the primary action fails or returns an unacceptable
  /// result.
  ///
  /// Place this **outermost** so it catches exhausted retries and open
  /// circuits:
  ///
  /// ```dart
  /// builder
  ///     .addFallbackPolicy(
  ///       fallbackAction: (ex, st) async =>
  ///           HttpResponse(statusCode: 200, body: 'cached data'.codeUnits),
  ///       classifier: const HttpOutcomeClassifier(),
  ///       onFallback: (ex, st) => log.warning('Fallback triggered: $ex'),
  ///     )
  ///     .addRetryPolicy(maxRetries: 3)
  ///     .addTimeout(const Duration(seconds: 10))
  /// ```
  ///
  /// [fallbackAction]     — async action returning a substitute result.
  /// [shouldHandle]       — exception filter; all exceptions handled when
  ///                        `null`.
  /// [shouldHandleResult] — result filter; triggers fallback when `true`.
  /// [classifier]         — [OutcomeClassifier]-based trigger (e.g. 5xx).
  /// [onFallback]         — logging/metrics callback fired before the fallback.
  /// [eventHub]           — optional hub for [FallbackEvent] notifications.
  ///
  FluentHttpClientBuilder addFallbackPolicy({
    required FallbackAction fallbackAction,
    FallbackExceptionPredicate? shouldHandle,
    FallbackResultPredicate? shouldHandleResult,
    OutcomeClassifier? classifier,
    FallbackCallback? onFallback,
    ResilienceEventHub? eventHub,
  }) =>
      _addStep(
        (b) => b.withPolicy(
          FallbackResiliencePolicy(
            fallbackAction: fallbackAction,
            shouldHandle: shouldHandle,
            shouldHandleResult: shouldHandleResult,
            classifier: classifier,
            onFallback: onFallback,
            eventHub: eventHub,
          ),
        ),
      );

  // ==========================================================================
  // Bulkhead policies
  // ==========================================================================

  /// Appends a [BulkheadResiliencePolicy] (via [PolicyHandler]) that limits
  /// parallel executions.
  ///
  /// Requests that exceed [maxConcurrency] are queued up to [maxQueueDepth]
  /// for at most [queueTimeout].  Excess requests are rejected with
  /// [BulkheadRejectedException].
  ///
  ///
  /// ```dart
  /// builder.addBulkheadPolicy(maxConcurrency: 20, maxQueueDepth: 100)
  /// ```
  FluentHttpClientBuilder addBulkheadPolicy({
    required int maxConcurrency,
    int maxQueueDepth = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    ResilienceEventHub? eventHub,
  }) =>
      _addStep(
        (b) => b.withPolicy(
          BulkheadResiliencePolicy(
            maxConcurrency: maxConcurrency,
            maxQueueDepth: maxQueueDepth,
            queueTimeout: queueTimeout,
            eventHub: eventHub,
          ),
        ),
      );

  /// Appends a [BulkheadIsolationResiliencePolicy] (via [PolicyHandler])
  /// that limits concurrent executions with a zero-polling semaphore.
  ///
  /// [maxConcurrentRequests] — maximum simultaneous executions (≥ 1).
  /// [maxQueueSize]          — maximum queued requests (0 = reject immediately).
  /// [queueTimeout]          — max wait time before rejection.
  /// [onRejected]            — optional callback on every rejection.
  ///
  /// ```dart
  /// builder.addBulkheadIsolationPolicy(
  ///   maxConcurrentRequests: 10,
  ///   maxQueueSize: 20,
  ///   queueTimeout: Duration(seconds: 5),
  /// )
  /// ```
  FluentHttpClientBuilder addBulkheadIsolationPolicy({
    int maxConcurrentRequests = 10,
    int maxQueueSize = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    BulkheadRejectedCallback? onRejected,
    ResilienceEventHub? eventHub,
  }) =>
      _addStep(
        (b) => b.withPolicy(
          BulkheadIsolationResiliencePolicy(
            maxConcurrentRequests: maxConcurrentRequests,
            maxQueueSize: maxQueueSize,
            queueTimeout: queueTimeout,
            onRejected: onRejected,
            eventHub: eventHub,
          ),
        ),
      );

  // ==========================================================================
  // Escape hatches
  // ==========================================================================

  /// Appends an arbitrary [ResiliencePolicy] (wrapped in a [PolicyHandler]) at
  /// the current pipeline position.
  ///
  /// Use this for policies obtained from a [PolicyRegistry] or for composed
  /// [ResiliencePipelineBuilder]-built pipelines:
  ///
  /// ```dart
  /// builder.withResiliencePolicy(
  ///   Policy.wrap([
  ///     Policy.timeout(const Duration(seconds: 5)),
  ///     Policy.circuitBreaker(circuitName: 'svc'),
  ///     Policy.retry(maxRetries: 3),
  ///   ]),
  /// )
  /// ```
  FluentHttpClientBuilder withResiliencePolicy(ResiliencePolicy policy) =>
      _addStep((b) => b.withPolicy(policy));

  /// Appends a raw [DelegatingHandler] at the current pipeline position.
  ///
  /// Use this when you need a handler that is not expressible as a
  /// [ResiliencePolicy] (e.g. a custom authentication handler, a caching
  /// handler, etc.).
  ///
  /// ```dart
  /// builder.withHandler(AuthHeaderHandler(tokenStore))
  /// ```
  FluentHttpClientBuilder withHandler(DelegatingHandler handler) =>
      _addStep((b) => b.addHandler(handler));

  // ==========================================================================
  // Build / registration
  // ==========================================================================

  /// Applies the accumulated configuration to [builder].
  ///
  /// This is an internal helper used by [build] and [done] but is also
  /// exposed publicly so the DSL configuration can be composed into an
  /// existing [HttpClientBuilder]:
  ///
  /// ```dart
  /// final existing = HttpClientBuilder('api')
  ///     ..withLogging();
  ///
  /// final dsl = FluentHttpClientBuilder()
  ///     .addRetryPolicy(maxRetries: 3)
  ///     .addTimeout(const Duration(seconds: 10));
  ///
  /// dsl.applyTo(existing); // merges DSL steps into existing builder
  /// final client = existing.build();
  /// ```
  void applyTo(HttpClientBuilder builder) {
    if (_baseUri != null) builder.withBaseUri(_baseUri!);
    for (final entry in _headers.entries) {
      builder.withDefaultHeader(entry.key, entry.value);
    }
    if (_httpClient != null) builder.withHttpClient(_httpClient!);
    for (final step in _steps) {
      step(builder);
    }
  }

  /// Builds and returns a [ResilientHttpClient] immediately.
  ///
  /// May be called multiple times; each call produces a freshly constructed
  /// client with an independent pipeline instance.
  ///
  /// ```dart
  /// final client = FluentHttpClientBuilder('catalog')
  ///     .withBaseUri(Uri.parse('https://catalog.svc/v2'))
  ///     .addRetryPolicy(maxRetries: 3)
  ///     .addTimeout(const Duration(seconds: 10))
  ///     .build();
  /// ```
  ResilientHttpClient build() {
    final builder = HttpClientBuilder(_name);
    applyTo(builder);
    return builder.build();
  }

  /// Registers this configuration with the bound [HttpClientFactory] and
  /// returns the factory for further chaining.
  ///
  /// The factory will build the client **lazily** the first time
  /// [HttpClientFactory.createClient] is called for [_name].  Calling
  /// [done] multiple times appends the configuration on each call — use only
  /// once per builder instance.
  ///
  /// Throws [StateError] when called on an unbound builder (i.e. a builder
  /// not obtained from [HttpClientFactoryFluentExtension.forClient]).
  ///
  /// ```dart
  /// final factory = HttpClientFactory()
  ///   ..forClient('api')
  ///       .addRetryPolicy(maxRetries: 3)
  ///       .addTimeout(const Duration(seconds: 10))
  ///       .done();
  ///
  /// final client = factory.createClient('api');
  /// ```
  HttpClientFactory done() {
    final factory = _factory;
    if (factory == null) {
      throw StateError(
        'FluentHttpClientBuilder.done() called on an unbound builder. '
        'Obtain a factory-bound builder via '
        'HttpClientFactory.forClient(name) instead of '
        'constructing FluentHttpClientBuilder directly.',
      );
    }
    factory.addClient(_name, applyTo);
    return factory;
  }

  // ==========================================================================
  // Inspection
  // ==========================================================================

  /// The diagnostic name label for this builder.
  String get name => _name;

  /// The number of pipeline steps currently registered.
  int get stepCount => _steps.length;

  /// Whether this builder is bound to an [HttpClientFactory] (i.e. was
  /// obtained from [HttpClientFactoryFluentExtension.forClient]).
  bool get isBound => _factory != null;

  @override
  String toString() {
    final label = _name.isEmpty ? 'unnamed' : '"$_name"';
    return 'FluentHttpClientBuilder($label, $stepCount step(s),'
        ' bound=$isBound)';
  }
}

// ============================================================================
// HttpClientFactory extension
// ============================================================================

/// Extends [HttpClientFactory] with a fluent DSL entry-point.
///
/// Import [FluentHttpClientBuilder] (or any file that exports it) to bring
/// this extension into scope.
extension HttpClientFactoryFluentExtension on HttpClientFactory {
  /// Returns a [FluentHttpClientBuilder] bound to this factory under [name].
  ///
  /// Configure the builder with the `add*` / `with*` methods, then call
  /// [FluentHttpClientBuilder.done] to register the configuration and receive
  /// the factory back for further chaining.
  ///
  /// Configuration is registered **lazily**: the [ResilientHttpClient] is only
  /// constructed when [HttpClientFactory.createClient] is first called.
  ///
  /// ```dart
  /// final factory = HttpClientFactory()
  ///   ..forClient('api')
  ///       .withBaseUri(Uri.parse('https://api.example.com'))
  ///       .addRetryPolicy(maxRetries: 3)
  ///       .addTimeout(const Duration(seconds: 10))
  ///       .done()
  ///   ..forClient('cdn')
  ///       .withBaseUri(Uri.parse('https://cdn.example.com'))
  ///       .addBulkheadPolicy(maxConcurrency: 50)
  ///       .done();
  ///
  /// final apiClient = factory.createClient('api');
  /// final cdnClient = factory.createClient('cdn');
  /// ```
  FluentHttpClientBuilder forClient(String name) => FluentHttpClientBuilder._(
        name: name,
        steps: const [],
        headers: const {},
        factory: this,
      );
}
