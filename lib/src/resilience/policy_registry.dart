import 'resilience_policy.dart';

/// A named registry for [ResiliencePolicy] instances.
///
/// [PolicyRegistry] is Dart's equivalent of Polly's `PolicyRegistry`: a
/// central store that maps string keys to [ResiliencePolicy] instances so that
/// policies configured once at startup — with the correct tuning parameters —
/// can be resolved by name throughout the application without creating new
/// instances on every call-site.
///
/// ---
///
/// ## Quick-start
///
/// ```dart
/// import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
///
/// // ----- Startup (once) -----
/// final registry = PolicyRegistry()
///   ..add('standard-retry', Policy.retry(
///       maxRetries: 3,
///       backoff: const ExponentialBackoff(Duration(milliseconds: 200))))
///   ..add('fast-timeout', Policy.timeout(const Duration(seconds: 3)))
///   ..add('slow-timeout', Policy.timeout(const Duration(seconds: 30)))
///   ..add('payments-cb', Policy.circuitBreaker(
///       circuitName: 'payments-api', failureThreshold: 5));
///
/// // ----- Resolution (anywhere) -----
/// final retry   = registry.get<RetryResiliencePolicy>('standard-retry');
/// final timeout = registry.get<TimeoutResiliencePolicy>('fast-timeout');
/// final cb      = registry.get<CircuitBreakerResiliencePolicy>('payments-cb');
/// ```
///
/// ---
///
/// ## Instance vs. global singleton
///
/// Create and inject a [PolicyRegistry] instance when you need
/// multiple independent registries or want explicit lifecycle control.
///
/// Use the lazy **[PolicyRegistry.instance]** when you want a single
/// process-wide store without passing the registry through the call stack:
///
/// ```dart
/// // Application setup
/// PolicyRegistry.instance
///   ..add('retry', Policy.retry(maxRetries: 3))
///   ..add('timeout', Policy.timeout(const Duration(seconds: 5)));
///
/// // Anywhere else in the process
/// final r = PolicyRegistry.instance.get<RetryResiliencePolicy>('retry');
/// ```
///
/// Reset the singleton (e.g. between test cases) with
/// [PolicyRegistry.resetInstance].
///
/// ---
///
/// ## Integration with HttpClientBuilder
///
/// The shortest path from registry to HTTP pipeline uses
/// [HttpClientBuilder.withPolicyFromRegistry]:
///
/// ```dart
/// final factory = HttpClientFactory()
///   ..addClient('payments', (b) => b
///       .withBaseUri(Uri.parse('https://payments.internal/v1'))
///       .withPolicyFromRegistry('fast-timeout', registry: registry)
///       .withPolicyFromRegistry('payments-cb', registry: registry)
///       .withPolicyFromRegistry('standard-retry', registry: registry));
///
/// final client = factory.createClient('payments');
/// ```
///
/// Using the global instance you can omit the `registry:` argument:
///
/// ```dart
/// builder.withPolicyFromRegistry('standard-retry');
/// ```
///
/// ---
///
/// ## Integration with ResiliencePipelineBuilder
///
/// ```dart
/// final policy = ResiliencePipelineBuilder()
///     .addPolicyFromRegistry('fast-timeout', registry: registry)
///     .addPolicyFromRegistry('payments-cb', registry: registry)
///     .addPolicyFromRegistry('standard-retry', registry: registry)
///     .build();
/// ```
///
/// ---
///
/// ## Thread safety
///
/// Dart's isolates run on a single-threaded event loop.  All reads and writes
/// to the underlying [Map] are synchronous and therefore automatically safe for
/// any number of concurrent async operations within the same isolate.
///
/// The registry does **not** share state across isolates — each isolate has its
/// own heap, so the global [PolicyRegistry.instance] is isolate-local.
final class PolicyRegistry {
  // --------------------------------------------------------------------------
  // Singleton
  // --------------------------------------------------------------------------

  /// The process-wide (isolate-local) lazily-initialised default registry.
  ///
  /// Populate this once at application startup and resolve from it anywhere
  /// without threading the registry through the call-stack.
  ///
  /// ```dart
  /// PolicyRegistry.instance
  ///   ..add('retry', Policy.retry(maxRetries: 3))
  ///   ..add('timeout', Policy.timeout(const Duration(seconds: 5)));
  /// ```
  static PolicyRegistry get instance => _instance ??= PolicyRegistry();
  static PolicyRegistry? _instance;

  /// Replaces the current [instance] with a freshly constructed registry.
  ///
  /// Useful in tests to guarantee isolation:
  ///
  /// ```dart
  /// tearDown(PolicyRegistry.resetInstance);
  /// ```
  static void resetInstance() => _instance = null;

  // --------------------------------------------------------------------------
  // Storage
  // --------------------------------------------------------------------------

  /// Creates a new, empty [PolicyRegistry].
  ///
  /// [namespace] — optional prefix applied to all key operations, enabling
  /// multiple independent registries to share the same logical names without
  /// collision:
  ///
  /// ```dart
  /// final tenantA = PolicyRegistry(namespace: 'tenant-A');
  /// final tenantB = PolicyRegistry(namespace: 'tenant-B');
  ///
  /// tenantA.add('retry', ...);  // stored as 'tenant-A:retry'
  /// tenantB.add('retry', ...);  // stored as 'tenant-B:retry'
  /// ```
  ///
  /// The default empty namespace preserves all existing behaviour.
  PolicyRegistry({String namespace = ''}) : _namespace = namespace;

  final String _namespace;
  final Map<String, ResiliencePolicy> _store = {};

  /// Applies the namespace prefix to a caller-supplied key.
  String _key(String name) =>
      _namespace.isEmpty ? name : '$_namespace:$name';

  /// Strips the namespace prefix from an internally stored key.
  String _strip(String key) =>
      _namespace.isEmpty ? key : key.substring(_namespace.length + 1);

  // --------------------------------------------------------------------------
  // Registration
  // --------------------------------------------------------------------------

  /// Registers [policy] under [name].
  ///
  /// Throws [StateError] if [name] is already registered.  Use
  /// [addOrReplace] when you want unconditional assignment.
  ///
  /// Returns `this` for fluent chaining:
  ///
  /// ```dart
  /// PolicyRegistry()
  ///   ..add('retry',   Policy.retry(maxRetries: 3))
  ///   ..add('timeout', Policy.timeout(const Duration(seconds: 5)));
  /// ```
  PolicyRegistry add(String name, ResiliencePolicy policy) {
    if (_store.containsKey(_key(name))) {
      throw StateError(
        'PolicyRegistry: a policy named "$name" is already registered. '
        'Call addOrReplace() to overwrite intentionally.',
      );
    }
    _store[_key(name)] = policy;
    return this;
  }

  /// Registers [policy] under [name], overwriting any existing entry.
  ///
  /// Prefer this over [add] when re-configuration at runtime is expected
  /// (e.g. tuning circuit-breaker thresholds after a deployment).
  ///
  /// Returns `this` for fluent chaining.
  PolicyRegistry addOrReplace(String name, ResiliencePolicy policy) {
    _store[_key(name)] = policy;
    return this;
  }

  /// Updates the policy registered under [name] to [policy].
  ///
  /// Throws [StateError] if [name] has never been registered.  This makes
  /// typos obvious at the call-site rather than silently adding a new entry.
  ///
  /// Returns `this` for fluent chaining.
  PolicyRegistry replace(String name, ResiliencePolicy policy) {
    if (!_store.containsKey(_key(name))) {
      throw StateError(
        'PolicyRegistry: no policy registered with name "$name". '
        'Call add() or addOrReplace() first.',
      );
    }
    _store[_key(name)] = policy;
    return this;
  }

  // --------------------------------------------------------------------------
  // Retrieval
  // --------------------------------------------------------------------------

  /// Returns the policy registered under [name], coerced to [T].
  ///
  /// Throws [StateError] if [name] is not registered.
  /// Throws [StateError] if the registered policy is not a [T].
  ///
  /// ```dart
  /// final retry = registry.get<RetryResiliencePolicy>('standard-retry');
  /// ```
  ///
  /// Omit the type argument to receive the base [ResiliencePolicy]:
  ///
  /// ```dart
  /// final policy = registry.get('standard-retry');
  /// ```
  T get<T extends ResiliencePolicy>(String name) {
    final policy = _store[_key(name)];
    if (policy == null) {
      throw StateError(
        'PolicyRegistry: no policy registered with name "$name".',
      );
    }
    if (policy is! T) {
      throw StateError(
        'PolicyRegistry: expected $T for "$name", '
        'found ${policy.runtimeType}.',
      );
    }
    return policy;
  }

  /// Returns the policy registered under [name] coerced to [T], or `null` if
  /// [name] is not registered or the policy is not a [T].
  ///
  /// Prefer this over [get] in contexts where an absent policy is a valid
  /// state rather than a programming error:
  ///
  /// ```dart
  /// final override = registry.tryGet<TimeoutResiliencePolicy>('custom-timeout');
  /// final effective = override ?? defaultTimeout;
  /// ```
  T? tryGet<T extends ResiliencePolicy>(String name) {
    final policy = _store[_key(name)];
    if (policy is T) return policy;
    return null;
  }

  // --------------------------------------------------------------------------
  // Removal
  // --------------------------------------------------------------------------

  /// Removes and returns the policy registered under [name], or `null` if
  /// [name] is not registered.
  ResiliencePolicy? remove(String name) => _store.remove(_key(name));

  /// Removes all registered policies, returning the registry to empty state.
  ///
  /// ```dart
  /// tearDown(registry.clear);
  /// ```
  PolicyRegistry clear() {
    _store.clear();
    return this;
  }

  // --------------------------------------------------------------------------
  // Introspection
  // --------------------------------------------------------------------------

  /// Returns `true` if a policy with [name] is registered.
  bool contains(String name) => _store.containsKey(_key(name));

  /// The number of registered policies.
  int get length => _store.length;

  /// Returns `true` when no policies are registered.
  bool get isEmpty => _store.isEmpty;

  /// Returns `true` when at least one policy is registered.
  bool get isNotEmpty => _store.isNotEmpty;

  /// An unmodifiable view of the registered policy names (without namespace prefix).
  Set<String> get keys => Set.unmodifiable(
        _namespace.isEmpty ? _store.keys : _store.keys.map(_strip),
      );

  /// An unmodifiable snapshot of the full registry as a [Map].
  ///
  /// Keys are returned without the namespace prefix.
  /// Mutations to the returned map do not affect the registry.
  Map<String, ResiliencePolicy> toMap() {
    if (_namespace.isEmpty) return Map.unmodifiable(_store);
    return Map.unmodifiable({
      for (final e in _store.entries) _strip(e.key): e.value,
    });
  }

  @override
  String toString() {
    if (_store.isEmpty) return 'PolicyRegistry(empty)';
    final entries = _store.entries
        .map((e) => '  "${_strip(e.key)}": ${e.value.runtimeType}')
        .join(',\n');
    return 'PolicyRegistry(${_store.length} policies) {\n$entries\n}';
  }
}
