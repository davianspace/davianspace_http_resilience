import '../resilience/backoff.dart';
import '../resilience/bulkhead_isolation_resilience_policy.dart';
import '../resilience/bulkhead_resilience_policy.dart';
import '../resilience/circuit_breaker_resilience_policy.dart';
import '../resilience/policy_registry.dart';
import '../resilience/resilience_pipeline_builder.dart';
import '../resilience/resilience_policy.dart';
import '../resilience/retry_resilience_policy.dart';
import '../resilience/timeout_resilience_policy.dart';
import 'resilience_config.dart';

/// Binds a [ResilienceConfig] to concrete [ResiliencePolicy] instances.
///
/// [ResilienceConfigBinder] is a pure factory — it is stateless and
/// `const`-constructible.  All methods return new policy instances on every
/// call so the same binder can be reused freely across isolates and test runs.
///
/// ## Building a complete pipeline
///
/// ```dart
/// const loader = ResilienceConfigLoader();
/// const binder = ResilienceConfigBinder();
///
/// final config = loader.load(jsonString);
/// final policy = binder.buildPipeline(config);
///
/// final response = await policy.execute(() => httpClient.get(uri));
/// ```
///
/// ## Building individual policies
///
/// ```dart
/// final retryPolicy   = binder.buildRetry(config.retry!);
/// final timeoutPolicy = binder.buildTimeout(config.timeout!);
/// ```
///
/// ## Default pipeline order
///
/// When more than one section is configured, [buildPipeline] assembles them
/// outermost-first in the order recommended for HTTP workloads:
///
/// 1. **Timeout** — hard upper bound on the whole operation.
/// 2. **CircuitBreaker** — fast-fail when the service is unhealthy.
/// 3. **BulkheadIsolation** (preferred) or **Bulkhead** — concurrency control.
/// 4. **Retry** — handle transient errors within the time budget.
///
/// If `config` has no sections set, [buildPipeline] returns an inert no-op
/// policy that simply delegates to the action.
final class ResilienceConfigBinder {
  /// Creates a [ResilienceConfigBinder].
  const ResilienceConfigBinder();

  // --------------------------------------------------------------------------
  // Pipeline builder
  // --------------------------------------------------------------------------

  /// Builds a single composed [ResiliencePolicy] from all sections present in
  /// [config].
  ///
  /// Returns a no-op pass-through policy when `config.isEmpty` is `true`.
  ResiliencePolicy buildPipeline(ResilienceConfig config) {
    if (config.isEmpty) return const _NoOpResiliencePolicy();

    final builder = ResiliencePipelineBuilder();

    if (config.timeout != null) {
      builder.addTimeout(config.timeout!.duration);
    }
    if (config.circuitBreaker != null) {
      final cb = config.circuitBreaker!;
      builder.addCircuitBreaker(
        circuitName: cb.circuitName,
        failureThreshold: cb.failureThreshold,
        successThreshold: cb.successThreshold,
        breakDuration: cb.breakDuration,
      );
    }
    // BulkheadIsolation takes precedence when both are present.
    if (config.bulkheadIsolation != null) {
      final bi = config.bulkheadIsolation!;
      builder.addBulkheadIsolation(
        maxConcurrentRequests: bi.maxConcurrentRequests,
        maxQueueSize: bi.maxQueueSize,
        queueTimeout: bi.queueTimeout,
      );
    } else if (config.bulkhead != null) {
      final bh = config.bulkhead!;
      builder.addBulkhead(
        maxConcurrency: bh.maxConcurrency,
        maxQueueDepth: bh.maxQueueDepth,
        queueTimeout: bh.queueTimeout,
      );
    }
    if (config.retry != null) {
      builder.addRetry(
        maxRetries: config.retry!.maxRetries,
        backoff: _buildBackoff(config.retry!.backoff),
        retryForever: config.retry!.retryForever,
      );
    }

    return builder.build();
  }

  // --------------------------------------------------------------------------
  // Individual policy builders
  // --------------------------------------------------------------------------

  /// Builds a [RetryResiliencePolicy] from [config].
  RetryResiliencePolicy buildRetry(RetryConfig config) {
    final backoff = _buildBackoff(config.backoff);
    if (config.retryForever) {
      return RetryResiliencePolicy.forever(backoff: backoff);
    }
    return RetryResiliencePolicy(
      maxRetries: config.maxRetries,
      backoff: backoff,
    );
  }

  /// Builds a [TimeoutResiliencePolicy] from [config].
  TimeoutResiliencePolicy buildTimeout(TimeoutConfig config) =>
      TimeoutResiliencePolicy(config.duration);

  /// Builds a [CircuitBreakerResiliencePolicy] from [config].
  CircuitBreakerResiliencePolicy buildCircuitBreaker(
    CircuitBreakerConfig config,
  ) =>
      CircuitBreakerResiliencePolicy(
        circuitName: config.circuitName,
        failureThreshold: config.failureThreshold,
        successThreshold: config.successThreshold,
        breakDuration: config.breakDuration,
      );

  /// Builds a [BulkheadResiliencePolicy] from [config].
  BulkheadResiliencePolicy buildBulkhead(BulkheadConfig config) =>
      BulkheadResiliencePolicy(
        maxConcurrency: config.maxConcurrency,
        maxQueueDepth: config.maxQueueDepth,
        queueTimeout: config.queueTimeout,
      );

  /// Builds a [BulkheadIsolationResiliencePolicy] from [config].
  BulkheadIsolationResiliencePolicy buildBulkheadIsolation(
    BulkheadIsolationConfig config,
  ) =>
      BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: config.maxConcurrentRequests,
        maxQueueSize: config.maxQueueSize,
        queueTimeout: config.queueTimeout,
      );

  // --------------------------------------------------------------------------
  // Backoff helper
  // --------------------------------------------------------------------------

  RetryBackoff _buildBackoff(BackoffConfig? config) {
    if (config == null) return const NoBackoff();
    final base = config.baseDuration;
    final maxDelay = config.maxDelay;
    return switch (config.type) {
      BackoffType.constant => ConstantBackoff(base),
      BackoffType.linear => maxDelay != null
          ? CappedBackoff(LinearBackoff(base), maxDelay)
          : LinearBackoff(base),
      BackoffType.exponential => ExponentialBackoff(
          base,
          maxDelay: maxDelay ?? const Duration(seconds: 30),
          useJitter: config.useJitter,
        ),
      BackoffType.decorrelatedJitter => DecorrelatedJitterBackoff(
          base,
          maxDelay: maxDelay ?? const Duration(seconds: 30),
        ),
      BackoffType.none => const NoBackoff(),
    };
  }
}

// ---------------------------------------------------------------------------
// No-op policy (returned when config is empty)
// ---------------------------------------------------------------------------

/// A [ResiliencePolicy] that executes the action with no additional behaviour.
///
/// Returned by [ResilienceConfigBinder.buildPipeline] when the supplied config
/// has no sections configured.
final class _NoOpResiliencePolicy extends ResiliencePolicy {
  const _NoOpResiliencePolicy();

  @override
  Future<T> execute<T>(Future<T> Function() action) => action();

  @override
  String toString() => 'NoOpResiliencePolicy()';
}

// ---------------------------------------------------------------------------
// PolicyRegistry extension
// ---------------------------------------------------------------------------

/// Extension on [PolicyRegistry] for loading policies from a [ResilienceConfig].
///
/// Registers each configured section under a conventional name:
///
/// | Section              | Default key          | With prefix `p`      |
/// |----------------------|----------------------|----------------------|
/// | [RetryConfig]        | `'retry'`            | `'p.retry'`          |
/// | [TimeoutConfig]      | `'timeout'`          | `'p.timeout'`        |
/// | [CircuitBreakerConfig] | `'circuit-breaker'` | `'p.circuit-breaker'`|
/// | [BulkheadConfig]     | `'bulkhead'`         | `'p.bulkhead'`       |
/// | [BulkheadIsolationConfig] | `'bulkhead-isolation'` | `'p.bulkhead-isolation'` |
///
/// ## Example
///
/// ```dart
/// const loader = ResilienceConfigLoader();
/// const binder = ResilienceConfigBinder();
///
/// final config = loader.load(jsonString);
///
/// // Register with default names:
/// PolicyRegistry.instance.loadFromConfig(config);
///
/// // Register under a namespace:
/// PolicyRegistry.instance.loadFromConfig(config, prefix: 'payments');
///
/// // Retrieve later:
/// final retry = PolicyRegistry.instance.get<RetryResiliencePolicy>('payments.retry');
/// ```
extension PolicyRegistryConfigExtension on PolicyRegistry {
  /// Registers policies derived from [config] using [binder].
  ///
  /// Keys follow the table above.  Existing keys are **not** overwritten;
  /// use [loadFromConfigOrReplace] if re-configuration at runtime is needed.
  ///
  /// Throws [StateError] if any key is already registered.
  void loadFromConfig(
    ResilienceConfig config, {
    ResilienceConfigBinder binder = const ResilienceConfigBinder(),
    String prefix = '',
  }) {
    final p = prefix.isEmpty ? '' : '$prefix.';
    if (config.retry != null) {
      add('${p}retry', binder.buildRetry(config.retry!));
    }
    if (config.timeout != null) {
      add('${p}timeout', binder.buildTimeout(config.timeout!));
    }
    if (config.circuitBreaker != null) {
      add(
        '${p}circuit-breaker',
        binder.buildCircuitBreaker(config.circuitBreaker!),
      );
    }
    if (config.bulkhead != null) {
      add('${p}bulkhead', binder.buildBulkhead(config.bulkhead!));
    }
    if (config.bulkheadIsolation != null) {
      add(
        '${p}bulkhead-isolation',
        binder.buildBulkheadIsolation(config.bulkheadIsolation!),
      );
    }
  }

  /// Like [loadFromConfig] but uses [addOrReplace] — safe for runtime
  /// re-configuration without throwing when a key already exists.
  void loadFromConfigOrReplace(
    ResilienceConfig config, {
    ResilienceConfigBinder binder = const ResilienceConfigBinder(),
    String prefix = '',
  }) {
    final p = prefix.isEmpty ? '' : '$prefix.';
    if (config.retry != null) {
      addOrReplace('${p}retry', binder.buildRetry(config.retry!));
    }
    if (config.timeout != null) {
      addOrReplace('${p}timeout', binder.buildTimeout(config.timeout!));
    }
    if (config.circuitBreaker != null) {
      addOrReplace(
        '${p}circuit-breaker',
        binder.buildCircuitBreaker(config.circuitBreaker!),
      );
    }
    if (config.bulkhead != null) {
      addOrReplace('${p}bulkhead', binder.buildBulkhead(config.bulkhead!));
    }
    if (config.bulkheadIsolation != null) {
      addOrReplace(
        '${p}bulkhead-isolation',
        binder.buildBulkheadIsolation(config.bulkheadIsolation!),
      );
    }
  }
}
