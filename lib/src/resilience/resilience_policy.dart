/// Abstract base class for all composable resilience policies.
///
/// A [ResiliencePolicy] wraps an arbitrary asynchronous [`action`] with a
/// specific resilience behaviour (retry, circuit-breaker, timeout, etc.).
/// Policies are **stateless** with respect to [execute]  they hold only
/// configuration, never per-request mutable state.
///
/// ## Execution model
///
/// When multiple policies are composed, each policy acts as a decorator around
/// the next one.  The **outermost** policy in the chain executes first, then
/// delegates inward, all the way down to the real action:
///
/// ```
/// outermost policy
///    next policy
///         innermost policy
///              action()           real work happens here
///         innermost result
///    next result
/// outermost result
/// ```
///
/// A typical production stack:
///
/// ```
/// TimeoutPolicy       (1) hard deadline on the entire operation
///   CircuitBreaker    (2) fast-fails when the downstream is unhealthy
///     Retry           (3) retries transient failures within the deadline
///       action()
/// ```
///
/// ## Composition  fluent chaining
///
/// ```dart
/// // Outermost policy is specified first.
/// final policy = Policy.timeout(const Duration(seconds: 5))
///     .wrap(Policy.circuitBreaker(circuitName: 'payments'))
///     .wrap(Policy.retry(maxRetries: 3));
///
/// final result = await policy.execute(() => client.get(uri));
/// ```
///
/// ## Composition  list form
///
/// ```dart
/// final policy = Policy.wrap([
///   Policy.timeout(const Duration(seconds: 5)),
///   Policy.circuitBreaker(circuitName: 'payments'),
///   Policy.retry(maxRetries: 3),
/// ]);
/// ```
///
/// ## Composition  builder form
///
/// ```dart
/// final policy = ResiliencePipelineBuilder()
///     .addTimeout(const Duration(seconds: 5))
///     .addCircuitBreaker(circuitName: 'payments')
///     .addRetry(maxRetries: 3)
///     .build();
/// ```
///
/// ## Direct execution
///
/// ```dart
/// final result = await policy.execute(() => client.get(uri));
/// ```
abstract class ResiliencePolicy {
  const ResiliencePolicy();

  // ---------------------------------------------------------------------------
  // Core API
  // ---------------------------------------------------------------------------

  /// Executes [action] with this policy's resilience behaviour applied.
  ///
  /// Returns the result of [action] on success.
  /// Throws a policy-specific exception when the behaviour is exhausted
  /// (e.g. [`RetryExhaustedException`], [`CircuitOpenException`]).
  Future<T> execute<T>(Future<T> Function() action);

  /// Releases any resources held by this policy.
  ///
  /// The default implementation is a no-op.  Subclasses that register external
  /// listeners (e.g. `CircuitBreakerResiliencePolicy`) should override this to
  /// clean them up.
  ///
  /// Calling [execute] after [dispose] is undefined behaviour.
  void dispose() {}

  // ---------------------------------------------------------------------------
  // Composition
  // ---------------------------------------------------------------------------

  /// Returns a [PolicyWrap] that applies **this** policy around [inner].
  ///
  /// Execution order: **this** runs first (outermost), then [inner].
  ///
  /// ```dart
  /// // timeout  circuitBreaker  retry  action()
  /// final p = Policy.timeout(Duration(seconds: 5))
  ///     .wrap(Policy.circuitBreaker(circuitName: 'svc'))
  ///     .wrap(Policy.retry(maxRetries: 3));
  /// await p.execute(action);
  /// ```
  ///
  /// When [inner] is itself a [PolicyWrap] the lists are **flattened** so that
  /// `policies` always reflects the complete ordered chain without nesting:
  ///
  /// ```dart
  /// final ab  = a.wrap(b);     // PolicyWrap([a, b])
  /// final abc = ab.wrap(c);    // PolicyWrap([a, b, c])   flat, not nested
  /// ```
  ResiliencePolicy wrap(ResiliencePolicy inner) {
    final innerList =
        inner is PolicyWrap ? inner.policies : <ResiliencePolicy>[inner];
    return PolicyWrap([this, ...innerList]);
  }
}

// ---------------------------------------------------------------------------
// PolicyWrap
// ---------------------------------------------------------------------------

/// Composes an **ordered list** of [ResiliencePolicy] instances into a single
/// executable policy.
///
/// Created by [ResiliencePolicy.wrap], [`Policy.wrap`], or
/// [`ResiliencePipelineBuilder.build`].  Prefer those APIs over constructing
/// [PolicyWrap] directly.
///
/// ### Execution order
///
/// Policies execute **outermost-first**: `policies[0]` wraps everything after
/// it, `policies[last]` is closest to the action.
///
/// ```
/// policies[0]  policies[1]    policies[n-1]  action()
/// ```
///
/// ### List-based design benefits
///
/// * **Introspection**: [`policies`] exposes every policy in declaration order.
/// * **Flattening**: chaining two [`PolicyWrap`]s via [`wrap`] merges their lists
///   no nested wrappers, no duplicated nesting in [`toString`].
/// * **Clean diagnostics**: [`toString`] shows the full ordered pipeline.
///
/// ### Example
///
/// ```dart
/// final pipeline = [`Policy.wrap`]([
///   [`Policy.timeout`](const Duration(seconds: 5)),
///   [`Policy.circuitBreaker`](circuitName: 'payments'),
///   [`Policy.retry`](maxRetries: 3),
/// ]);
///
/// // Inspect the chain:
/// print(pipeline.policies.length);  // 3
/// print(pipeline.policies[0]);      // TimeoutResiliencePolicy(timeout=0:00:05.000000)
///
/// // Execute:
/// final result = await pipeline.execute(() => makeRequest());
/// ```
final class PolicyWrap extends ResiliencePolicy {
  /// Creates a [PolicyWrap] from an ordered [policies] list.
  ///
  /// [`policies`] must contain at least two entries.  Use [`Policy.wrap``] or
  /// [`ResiliencePolicy.wrap`] for ergonomic construction.
  PolicyWrap(List<ResiliencePolicy> policies)
      : assert(
          policies.length >= 2,
          'PolicyWrap requires at least 2 policies; '
          'use the policy directly for a single-policy chain.',
        ),
        policies = List.unmodifiable(policies);

  /// The ordered chain of policies, outermost first.
  ///
  /// `policies[0]` is the outermost wrapper (executes first).
  /// `policies[last]` is the innermost (executes last, just before the
  /// real action).
  ///
  /// The list is **unmodifiable**  build a new [PolicyWrap] to alter the
  /// chain.
  final List<ResiliencePolicy> policies;

  @override
  Future<T> execute<T>(Future<T> Function() action) {
    // Build the call chain from innermost outward so that when current() is
    // invoked, policies[0] (outermost) is entered first.
    Future<T> Function() current = action;
    for (final policy in policies.reversed) {
      final next = current; // capture loop variable for closure
      current = () => policy.execute(next);
    }
    return current();
  }

  /// Returns a [PolicyWrap] with [inner] appended to the end of [policies].
  ///
  /// If [inner] is itself a [PolicyWrap] its policies are merged (flattened)
  /// rather than nested, keeping [policies] a flat, readable list.
  @override
  ResiliencePolicy wrap(ResiliencePolicy inner) {
    final innerList =
        inner is PolicyWrap ? inner.policies : <ResiliencePolicy>[inner];
    return PolicyWrap([...policies, ...innerList]);
  }

  @override
  String toString() {
    final chain = policies.map((p) => '   $p').join('\n');
    return 'PolicyWrap(${policies.length} policies):\n$chain';
  }

  /// Disposes every policy in the chain.
  @override
  void dispose() {
    for (final policy in policies) {
      policy.dispose();
    }
  }
}
