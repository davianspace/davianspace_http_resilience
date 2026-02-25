/// Top-level resilience configuration parsed from a JSON config file.
///
/// Each property maps to a specific resilience policy section.  A `null`
/// section means that policy is not configured and should not be added to
/// the pipeline.
///
/// ## Example JSON
/// ```json
/// {
///   "Resilience": {
///     "Retry": { "MaxRetries": 3, "Backoff": { "Type": "exponential", "BaseMs": 200 } },
///     "Timeout": { "Seconds": 10 },
///     "CircuitBreaker": { "CircuitName": "api", "FailureThreshold": 5, "BreakSeconds": 30 },
///     "Bulkhead": { "MaxConcurrency": 20 },
///     "BulkheadIsolation": { "MaxConcurrentRequests": 10 },
///     "Hedging": { "HedgeAfterMs": 300, "MaxHedgedAttempts": 2 },
///     "Fallback": { "StatusCodes": [500, 502, 503, 504] }
///   }
/// }
/// ```
final class ResilienceConfig {
  /// Creates a [ResilienceConfig] with the given policy sections.
  const ResilienceConfig({
    this.retry,
    this.timeout,
    this.circuitBreaker,
    this.bulkhead,
    this.bulkheadIsolation,
    this.hedging,
    this.fallback,
  });

  /// Retry policy configuration.  `null` means no retry policy is configured.
  final RetryConfig? retry;

  /// Timeout policy configuration.  `null` means no timeout is configured.
  final TimeoutConfig? timeout;

  /// Circuit-breaker policy configuration.
  final CircuitBreakerConfig? circuitBreaker;

  /// Bulkhead (concurrency-limiting) policy configuration.
  final BulkheadConfig? bulkhead;

  /// Bulkhead-isolation policy configuration. Takes precedence over [bulkhead]
  /// when both are present.
  final BulkheadIsolationConfig? bulkheadIsolation;

  /// Hedging policy configuration.  `null` means no hedging is configured.
  final HedgingConfig? hedging;

  /// Fallback policy configuration.  `null` means no fallback is configured.
  ///
  /// **Note:** The [FallbackConfig] only configures which status codes trigger
  /// a fallback.  The actual fallback action (producing the `HttpResponse`) is
  /// always supplied programmatically because it cannot be expressed in JSON.
  final FallbackConfig? fallback;

  /// Returns `true` when no policy section is configured.
  bool get isEmpty =>
      retry == null &&
      timeout == null &&
      circuitBreaker == null &&
      bulkhead == null &&
      bulkheadIsolation == null &&
      hedging == null &&
      fallback == null;

  @override
  String toString() => 'ResilienceConfig('
      'retry: $retry, '
      'timeout: $timeout, '
      'circuitBreaker: $circuitBreaker, '
      'bulkhead: $bulkhead, '
      'bulkheadIsolation: $bulkheadIsolation, '
      'hedging: $hedging, '
      'fallback: $fallback)';
}

// ---------------------------------------------------------------------------
// Per-policy config classes
// ---------------------------------------------------------------------------

/// Configuration for a retry policy.
final class RetryConfig {
  /// Creates a [RetryConfig].
  ///
  /// [maxRetries] must be non-negative.
  const RetryConfig({
    this.maxRetries = 3,
    this.retryForever = false,
    this.backoff,
  }) : assert(maxRetries >= 0, 'maxRetries must be >= 0');

  /// Maximum number of additional attempts after the initial call.
  ///
  /// Ignored when [retryForever] is `true`.
  final int maxRetries;

  /// When `true`, retries indefinitely until the action succeeds.
  final bool retryForever;

  /// Back-off strategy to apply between retries.  `null` means no delay
  /// (equivalent to [BackoffType.none]).
  final BackoffConfig? backoff;

  @override
  String toString() => 'RetryConfig('
      'maxRetries: $maxRetries, '
      'retryForever: $retryForever, '
      'backoff: $backoff)';
}

/// Configuration for a timeout policy.
final class TimeoutConfig {
  /// Creates a [TimeoutConfig] with the given [seconds].
  ///
  /// [seconds] must be positive.
  const TimeoutConfig({required this.seconds})
      : assert(seconds > 0, 'seconds must be > 0');

  /// Timeout duration in whole seconds.
  final int seconds;

  /// [seconds] expressed as a [Duration].
  Duration get duration => Duration(seconds: seconds);

  @override
  String toString() => 'TimeoutConfig(seconds: $seconds)';
}

/// Configuration for a circuit-breaker policy.
final class CircuitBreakerConfig {
  /// Creates a [CircuitBreakerConfig].
  ///
  /// [failureThreshold] and [successThreshold] must be positive.
  /// [breakSeconds] must be non-negative.
  const CircuitBreakerConfig({
    this.circuitName = 'default',
    this.failureThreshold = 5,
    this.successThreshold = 1,
    this.breakSeconds = 30,
  })  : assert(failureThreshold > 0, 'failureThreshold must be > 0'),
        assert(successThreshold > 0, 'successThreshold must be > 0'),
        assert(breakSeconds >= 0, 'breakSeconds must be >= 0');

  /// Logical name of the circuit.  Circuits with the same name share state.
  final String circuitName;

  /// Consecutive failures before the circuit opens.
  final int failureThreshold;

  /// Consecutive successes in half-open state required to close the circuit.
  final int successThreshold;

  /// Seconds the circuit stays open before transitioning to half-open.
  final int breakSeconds;

  /// [breakSeconds] expressed as a [Duration].
  Duration get breakDuration => Duration(seconds: breakSeconds);

  @override
  String toString() => 'CircuitBreakerConfig('
      'circuitName: $circuitName, '
      'failureThreshold: $failureThreshold, '
      'successThreshold: $successThreshold, '
      'breakSeconds: $breakSeconds)';
}

/// Configuration for a bulkhead (concurrency-limiting) policy.
final class BulkheadConfig {
  /// Creates a [BulkheadConfig].
  ///
  /// [maxConcurrency] must be positive. [maxQueueDepth] must be non-negative.
  const BulkheadConfig({
    required this.maxConcurrency,
    this.maxQueueDepth = 100,
    this.queueTimeoutSeconds = 10,
  })  : assert(maxConcurrency >= 1, 'maxConcurrency must be >= 1'),
        assert(maxQueueDepth >= 0, 'maxQueueDepth must be >= 0'),
        assert(queueTimeoutSeconds >= 0, 'queueTimeoutSeconds must be >= 0');

  /// Maximum number of actions executing concurrently (must be ≥ 1).
  final int maxConcurrency;

  /// Maximum number of actions waiting in the queue.
  final int maxQueueDepth;

  /// Seconds a queued request may wait before being rejected.
  final int queueTimeoutSeconds;

  /// [queueTimeoutSeconds] expressed as a [Duration].
  Duration get queueTimeout => Duration(seconds: queueTimeoutSeconds);

  @override
  String toString() => 'BulkheadConfig('
      'maxConcurrency: $maxConcurrency, '
      'maxQueueDepth: $maxQueueDepth, '
      'queueTimeoutSeconds: $queueTimeoutSeconds)';
}

/// Configuration for a bulkhead-isolation policy.
final class BulkheadIsolationConfig {
  /// Creates a [BulkheadIsolationConfig].
  ///
  /// [maxConcurrentRequests] must be positive. [maxQueueSize] must be
  /// non-negative.
  const BulkheadIsolationConfig({
    this.maxConcurrentRequests = 10,
    this.maxQueueSize = 100,
    this.queueTimeoutSeconds = 10,
  })  : assert(
          maxConcurrentRequests >= 1,
          'maxConcurrentRequests must be >= 1',
        ),
        assert(maxQueueSize >= 0, 'maxQueueSize must be >= 0'),
        assert(queueTimeoutSeconds >= 0, 'queueTimeoutSeconds must be >= 0');

  /// Maximum number of requests executing concurrently.
  final int maxConcurrentRequests;

  /// Maximum number of requests queued waiting for a slot.
  final int maxQueueSize;

  /// Seconds a queued request may wait before being rejected.
  final int queueTimeoutSeconds;

  /// [queueTimeoutSeconds] expressed as a [Duration].
  Duration get queueTimeout => Duration(seconds: queueTimeoutSeconds);

  @override
  String toString() => 'BulkheadIsolationConfig('
      'maxConcurrentRequests: $maxConcurrentRequests, '
      'maxQueueSize: $maxQueueSize, '
      'queueTimeoutSeconds: $queueTimeoutSeconds)';
}

/// Configuration for a retry back-off strategy.
final class BackoffConfig {
  /// Creates a [BackoffConfig].
  const BackoffConfig({
    this.type = BackoffType.none,
    this.baseMs = 200,
    this.maxDelayMs,
    this.useJitter = false,
  });

  /// The back-off algorithm to use.
  final BackoffType type;

  /// Base delay in milliseconds.
  final int baseMs;

  /// Optional cap on the computed delay in milliseconds.
  final int? maxDelayMs;

  /// When `true` and [type] supports jitter, enables full-jitter.
  ///
  /// Applicable to [BackoffType.exponential].
  final bool useJitter;

  /// [baseMs] expressed as a [Duration].
  Duration get baseDuration => Duration(milliseconds: baseMs);

  /// [maxDelayMs] expressed as a [Duration], or `null` if not set.
  Duration? get maxDelay =>
      maxDelayMs != null ? Duration(milliseconds: maxDelayMs!) : null;

  @override
  String toString() => 'BackoffConfig('
      'type: $type, '
      'baseMs: $baseMs, '
      'maxDelayMs: $maxDelayMs, '
      'useJitter: $useJitter)';
}

/// Configuration for a hedging policy.
///
/// Hedging fires speculative concurrent requests to reduce tail latency.
/// Only configure hedging for **idempotent** operations.
///
/// ## Example JSON
/// ```json
/// {
///   "Hedging": {
///     "HedgeAfterMs": 300,
///     "MaxHedgedAttempts": 2
///   }
/// }
/// ```
final class HedgingConfig {
  /// Creates a [HedgingConfig].
  ///
  /// [hedgeAfterMs] must be non-negative. [maxHedgedAttempts] must be >= 1.
  const HedgingConfig({
    this.hedgeAfterMs = 200,
    this.maxHedgedAttempts = 1,
  })  : assert(hedgeAfterMs >= 0, 'hedgeAfterMs must be >= 0'),
        assert(maxHedgedAttempts >= 1, 'maxHedgedAttempts must be >= 1');

  /// Milliseconds to wait before launching the next speculative request.
  final int hedgeAfterMs;

  /// Number of additional concurrent requests on top of the original.
  final int maxHedgedAttempts;

  /// [hedgeAfterMs] expressed as a [Duration].
  Duration get hedgeAfter => Duration(milliseconds: hedgeAfterMs);

  @override
  String toString() => 'HedgingConfig('
      'hedgeAfterMs: $hedgeAfterMs, '
      'maxHedgedAttempts: $maxHedgedAttempts)';
}

/// Configuration for a fallback policy.
///
/// Because a fallback action cannot be expressed in JSON (it is Dart code),
/// this config class only captures the **trigger** configuration — which HTTP
/// status codes should activate the fallback.  The actual fallback action must
/// be supplied programmatically via `ResilienceConfigBinder.buildPipeline` or
/// `ResilienceConfigBinder.buildFallbackPolicy`.
///
/// ## Example JSON
/// ```json
/// {
///   "Fallback": {
///     "StatusCodes": [500, 502, 503, 504]
///   }
/// }
/// ```
final class FallbackConfig {
  /// Creates a [FallbackConfig].
  const FallbackConfig({
    this.statusCodes = const [500, 502, 503, 504],
  });

  /// HTTP status codes that trigger the fallback.
  ///
  /// Any exception also triggers the fallback regardless of this list.
  final List<int> statusCodes;

  @override
  String toString() => 'FallbackConfig(statusCodes: $statusCodes)';
}

/// Identifies the back-off algorithm used between retry attempts.
enum BackoffType {
  /// No delay — retries immediately.
  none,

  /// Fixed delay of [BackoffConfig.baseMs] milliseconds between every attempt.
  constant,

  /// Linearly increasing delay: `base × attempt`.
  linear,

  /// Exponentially increasing delay: `base × 2^(attempt−1)`, capped at
  /// [BackoffConfig.maxDelayMs].  Supports jitter via [BackoffConfig.useJitter].
  exponential,

  /// AWS-style decorrelated jitter: random delay in
  /// `[base, min(maxDelay, base × 3^(attempt−1))]`.
  decorrelatedJitter,
}
