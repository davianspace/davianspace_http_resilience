import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../handlers/bulkhead_handler.dart';
import '../handlers/bulkhead_isolation_handler.dart';
import '../handlers/circuit_breaker_handler.dart';
import '../handlers/fallback_handler.dart';
import '../handlers/hedging_handler.dart';
import '../handlers/logging_handler.dart';
import '../handlers/policy_handler.dart';
import '../handlers/retry_handler.dart';
import '../handlers/timeout_handler.dart';
import '../pipeline/delegating_handler.dart';
import '../pipeline/http_pipeline_builder.dart';
import '../pipeline/terminal_handler.dart';
import '../policies/bulkhead_isolation_policy.dart';
import '../policies/bulkhead_policy.dart';
import '../policies/circuit_breaker_policy.dart';
import '../policies/fallback_policy.dart';
import '../policies/hedging_policy.dart';
import '../policies/retry_policy.dart';
import '../policies/timeout_policy.dart';
import '../resilience/policy_registry.dart';
import '../resilience/resilience_policy.dart';
import 'resilient_http_client.dart';

// ============================================================================
// HttpClientBuilder
// ============================================================================

/// Fluent builder for constructing a [ResilientHttpClient] with an ordered
/// middleware pipeline.
///
/// Obtain an instance via [HttpClientFactory.addClient] (preferred) or
/// construct one directly for lightweight use without a factory.
///
/// ### Recommended handler order (outermost  innermost)
///
/// ```
/// LoggingHandler          1. measures full round-trip, sees all retries
/// PolicyHandler(retry)    2. retry wraps everything below
/// PolicyHandler(cb)       3. circuit guard evaluated per attempt
/// PolicyHandler(timeout)  4. per-attempt time budget
/// BulkheadHandler         5. max-concurrency semaphore
/// TerminalHandler         6. real HTTP I/O
/// ```
///
/// ## Example
///
/// ```dart
/// final factory = HttpClientFactory()
///   ..addClient('catalog', (b) => b
///       .withBaseUri(Uri.parse('https://catalog.svc/v2'))
///       .withDefaultHeader('Accept', 'application/json')
///       .withLogging()
///       .withRetry(RetryPolicy.exponential(maxRetries: 3, useJitter: true))
///       .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'catalog'))
///       .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10)))
///       .withBulkhead(BulkheadPolicy(maxConcurrency: 20)));
///
/// final client = factory.createClient('catalog');
/// ```
final class HttpClientBuilder {
  /// Creates an [HttpClientBuilder] with an optional diagnostic name label.
  HttpClientBuilder([this._name = '']);

  final String _name;
  Uri? _baseUri;
  final Map<String, String> _defaultHeaders = {};
  final List<DelegatingHandler> _handlers = [];
  http.Client? _httpClient;
  bool _streamingMode = false;

  // --------------------------------------------------------------------------
  // Configuration methods
  // --------------------------------------------------------------------------

  /// Sets the base [Uri] used to resolve relative request URIs.
  ///
  /// When set, every `get/post/...` call resolves its [Uri] argument against
  /// this base using [Uri.resolveUri].
  HttpClientBuilder withBaseUri(Uri baseUri) {
    _baseUri = baseUri;
    return this;
  }

  /// Adds a header that will be merged into every outgoing request.
  ///
  /// Per-request headers take precedence over defaults.
  HttpClientBuilder withDefaultHeader(String name, String value) {
    _defaultHeaders[name] = value;
    return this;
  }

  /// Adds a [LoggingHandler] at the current pipeline position.
  ///
  /// Place this as the outermost handler so it measures the complete
  /// round-trip duration including all retries.
  HttpClientBuilder withLogging({Logger? logger}) {
    _handlers.add(LoggingHandler(logger: logger));
    return this;
  }

  /// Adds a [RetryHandler] configured with [policy].
  HttpClientBuilder withRetry(RetryPolicy policy) {
    _handlers.add(RetryHandler(policy));
    return this;
  }

  /// Adds a [CircuitBreakerHandler] configured with [policy].
  HttpClientBuilder withCircuitBreaker(
    CircuitBreakerPolicy policy, {
    CircuitBreakerRegistry? registry,
  }) {
    _handlers.add(CircuitBreakerHandler(policy, registry: registry));
    return this;
  }

  /// Adds a [TimeoutHandler] configured with [policy].
  HttpClientBuilder withTimeout(TimeoutPolicy policy) {
    _handlers.add(TimeoutHandler(policy));
    return this;
  }

  /// Adds a [BulkheadHandler] configured with [policy].
  HttpClientBuilder withBulkhead(BulkheadPolicy policy) {
    _handlers.add(BulkheadHandler(policy));
    return this;
  }

  /// Adds a [BulkheadIsolationHandler] configured with [policy].
  ///
  /// Uses an efficient zero-polling [BulkheadIsolationSemaphore].  Place
  /// this **innermost** (closest to the terminal handler) so outer retry
  /// and fallback handlers see it as a single rate-limited unit:
  ///
  /// ```dart
  /// builder
  ///     .withFallback(fallbackPolicy)
  ///     .withRetry(retryPolicy)
  ///     .withBulkheadIsolation(
  ///       BulkheadIsolationPolicy(
  ///         maxConcurrentRequests: 10,
  ///         maxQueueSize: 20,
  ///       ),
  ///     );
  /// ```
  HttpClientBuilder withBulkheadIsolation(BulkheadIsolationPolicy policy) {
    _handlers.add(BulkheadIsolationHandler(policy));
    return this;
  }

  /// Adds a [FallbackHandler] configured with [policy].
  ///
  /// Place this **before** retry / circuit-breaker handlers so it wraps them
  /// and catches their final, exhausted exceptions:
  ///
  /// ```dart
  /// HttpClientFactory.create('catalog')
  ///     .withFallback(
  ///       FallbackPolicy(
  ///         fallbackAction: (ctx, err, st) async =>
  ///             HttpResponse.cached('offline data'),
  ///         classifier: const HttpOutcomeClassifier(),
  ///         onFallback: (ctx, err, _) =>
  ///             log.warning('Fallback for ${ctx.request.uri}'),
  ///       ),
  ///     )
  ///     .withRetry(RetryPolicy.exponential(maxRetries: 3))
  ///     .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10)))
  ///     .build();
  /// ```
  HttpClientBuilder withFallback(FallbackPolicy policy) {
    _handlers.add(FallbackHandler(policy));
    return this;
  }

  /// Adds a [PolicyHandler] that applies a free-standing [ResiliencePolicy] to
  /// every request at this pipeline position.
  ///
  /// Use this to attach composable [ResiliencePolicy] pipelines  including
  /// `PolicyWrap` and `ResiliencePipelineBuilder` results — directly
  /// to the HTTP pipeline:
  ///
  /// ```dart
  /// builder.withPolicy(
  ///   Policy.wrap([
  ///     Policy.timeout(const Duration(seconds: 10)),
  ///     Policy.circuitBreaker(circuitName: 'payments', failureThreshold: 5),
  ///     Policy.retry(maxRetries: 3),
  ///   ]),
  /// );
  /// ```
  HttpClientBuilder withPolicy(ResiliencePolicy policy) {
    _handlers.add(PolicyHandler(policy));
    return this;
  }

  /// Resolves [policyName] from [registry] (or from [PolicyRegistry.instance]
  /// when [registry] is omitted) and adds the result as a [PolicyHandler] at
  /// the current pipeline position.
  ///
  /// This is the primary integration point between [PolicyRegistry] and
  /// [HttpClientBuilder]:
  ///
  /// ```dart
  /// final factory = HttpClientFactory()
  ///   ..addClient('payments', (b) => b
  ///       .withPolicyFromRegistry('fast-timeout', registry: registry)
  ///       .withPolicyFromRegistry('payments-cb',  registry: registry)
  ///       .withPolicyFromRegistry('standard-retry', registry: registry));
  /// ```
  ///
  /// Throws [StateError] if [policyName] is not found in the registry.
  HttpClientBuilder withPolicyFromRegistry(
    String policyName, {
    PolicyRegistry? registry,
  }) =>
      withPolicy((registry ?? PolicyRegistry.instance).get(policyName));

  /// Injects a custom middleware [handler] at the current pipeline position.
  HttpClientBuilder addHandler(DelegatingHandler handler) {
    _handlers.add(handler);
    return this;
  }

  /// Overrides the underlying [http.Client] (useful for testing with mocks).
  ///
  /// ```dart
  /// import 'package:http/testing.dart';
  ///
  /// final builder = HttpClientBuilder()
  ///     .withHttpClient(MockClient((req) async => http.Response('OK', 200)));
  /// ```
  HttpClientBuilder withHttpClient(http.Client client) {
    _httpClient = client;
    return this;
  }

  /// Enables streaming mode for this client.
  ///
  /// When streaming mode is active, the [TerminalHandler] does **not** buffer
  /// the response body.  Instead, `response.isStreaming == true` and the body
  /// bytes are available via `response.bodyStream`.
  ///
  /// Streaming is ideal for large file downloads or Server-Sent Events where
  /// buffering the entire body would be wasteful or impossible.
  ///
  /// Adds a [HedgingHandler] configured with [policy].
  ///
  /// Hedging fires identical concurrent speculative requests to reduce tail
  /// latency (p95+). Place this **after** [withLogging] and **before** retry
  /// or circuit-breaker handlers so the hedging window spans only the
  /// actual HTTP round-trip:
  ///
  /// ```dart
  /// builder
  ///     .withLogging()
  ///     .withHedging(HedgingPolicy(
  ///       hedgeAfter: Duration(milliseconds: 200),
  ///       maxHedgedAttempts: 1,
  ///     ));
  /// ```
  ///
  /// **Only use hedging for idempotent operations** (GET, HEAD, PUT, DELETE).
  /// Never hedge POST or PATCH without server-side idempotency guarantees.
  HttpClientBuilder withHedging(HedgingPolicy policy) {
    _handlers.add(HedgingHandler(policy));
    return this;
  }

  /// **Incompatibility:** [RetryHandler] and [CircuitBreakerHandler] inspect
  /// the response status code (not the body), so they remain fully compatible
  /// with streaming mode.  However any handler that reads `response.body`
  /// bytes will receive `null` — those handlers must call
  /// `await response.toBuffered()` before inspecting bytes.
  HttpClientBuilder withStreamingMode() {
    _streamingMode = true;
    return this;
  }

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  /// Assembles and returns the [ResilientHttpClient].
  ///
  /// May be called multiple times; each call produces a freshly constructed
  /// client with an independent pipeline instance.
  ResilientHttpClient build() {
    final terminal = TerminalHandler(
      client: _httpClient,
      streamingMode: _streamingMode,
    );

    final pipelineBuilder = HttpPipelineBuilder()
      ..withTerminalHandler(terminal);

    for (final h in _handlers) {
      pipelineBuilder.addHandler(h);
    }

    // Capture handler list so dispose can clean up policy resources
    // (e.g. circuit-breaker listener subscriptions).
    final capturedHandlers = List<DelegatingHandler>.of(_handlers);

    return ResilientHttpClient(
      pipeline: pipelineBuilder.build(),
      baseUri: _baseUri,
      defaultHeaders: Map.unmodifiable(_defaultHeaders),
      onDispose: () {
        terminal.dispose();
        for (final h in capturedHandlers) {
          if (h is PolicyHandler) h.policy.dispose();
        }
      },
    );
  }

  @override
  String toString() {
    final label = _name.isEmpty ? 'unnamed' : _name;
    return 'HttpClientBuilder($label, ${_handlers.length} handler(s))';
  }
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Internal per-name registration: holds per-client configurators and a
/// lazily-built [ResilientHttpClient] cache.
final class _ClientRegistration {
  _ClientRegistration(this.name);

  final String name;

  final List<void Function(HttpClientBuilder)> _configs = [];

  ResilientHttpClient? _cached;

  void addConfig(void Function(HttpClientBuilder) config) {
    _configs.add(config);
    _cached = null; // new configurator -> must rebuild
  }

  /// Disposes the cached client (if any) and clears the cache so it is
  /// rebuilt on the next `createClient` call.
  void invalidate() {
    _cached?.dispose();
    _cached = null;
  }

  List<void Function(HttpClientBuilder)> get configs =>
      List.unmodifiable(_configs);
}

/// Base interface for typed-client registry entries (erases T).
abstract class _TypedEntryBase {
  /// Name of the named client that backs this typed client.
  String get clientName;

  /// Clears the cached typed-client instance.
  void invalidate();
}

/// Stores a typed-client factory function and its cached result.
final class _TypedEntry<T extends Object> implements _TypedEntryBase {
  _TypedEntry({required this.clientName, required this.factory});

  @override
  final String clientName;

  final T Function(ResilientHttpClient) factory;

  T? _cached;

  @override
  void invalidate() => _cached = null;

  T getOrCreate(ResilientHttpClient client) => _cached ??= factory(client);
}

// ============================================================================
// HttpClientFactory
// ============================================================================

/// An instance-based factory for creating and caching named and typed
/// [ResilientHttpClient] instances, inspired by
/// `Microsoft.Extensions.Http.IHttpClientFactory`.
///
/// ---
///
/// ## Quick-start
///
/// ```dart
/// final factory = HttpClientFactory()
///   ..configureDefaults((b) => b
///       .withDefaultHeader('Accept', 'application/json')
///       .withLogging())
///   ..addClient('catalog', (b) => b
///       .withBaseUri(Uri.parse('https://catalog.svc/v2'))
///       .withRetry(RetryPolicy.exponential(maxRetries: 3, useJitter: true))
///       .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'catalog'))
///       .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10))))
///   ..addTypedClient<CatalogService>(
///       (client) => CatalogService(client),
///       clientName: 'catalog');
///
/// final raw     = factory.createClient('catalog');
/// final service = factory.createTypedClient<CatalogService>();
/// ```
///
/// ---
///
/// ## Named clients
///
/// Register a named client with [addClient]. Each unique name maintains its
/// own pipeline configuration and cached instance:
///
/// ```dart
/// factory.addClient('payments', (b) => b
///     .withBaseUri(Uri.parse('https://payments.internal/v1'))
///     .withPolicy(Policy.wrap([
///       Policy.timeout(const Duration(seconds: 5)),
///       Policy.retry(maxRetries: 2),
///     ])));
///
/// final client = factory.createClient('payments');
/// ```
///
/// Calling [addClient] with the same name multiple times **appends**
/// configurators; the cached client is invalidated so the next
/// [createClient] rebuilds it.
///
/// ---
///
/// ## Typed clients
///
/// Typed clients wrap a [ResilientHttpClient] in a domain-specific service
/// class:
///
/// ```dart
/// class UserService {
///   UserService(this._client);
///   final ResilientHttpClient _client;
///   Future<HttpResponse> getUser(int id) =>
///       _client.get(Uri.parse('/users/`$id`'));
/// }
///
/// factory.addTypedClient<UserService>(
///   (client) => UserService(client),
///   clientName: 'users-api',
///   configure: (b) => b.withBaseUri(Uri.parse('https://users.svc/v1')),
/// );
///
/// final service = factory.createTypedClient<UserService>();
/// ```
///
/// ---
///
/// ## Default configuration
///
/// [configureDefaults] applies a configurator to **every** client created by
/// this factory.  Defaults run before per-client configurators, so
/// per-client settings can override them:
///
/// ```dart
/// factory.configureDefaults((b) => b
///     .withDefaultHeader('Accept', 'application/json')
///     .withLogging());
/// ```
///
/// ---
///
/// ## Caching and reuse
///
/// [createClient] and [createTypedClient] return the **same** instance on
/// repeated calls (lazy build, eager cache).  Use [invalidate] to force a
/// rebuild:
///
/// ```dart
/// factory.invalidate('payments'); // rebuild 'payments' next call
/// factory.invalidate();           // rebuild everything
/// ```
///
/// ---
///
/// ## Lifecycle
///
/// Call [clear] to remove all registrations and cached instances.  Useful
/// in application teardown or between test cases:
///
/// ```dart
/// factory.clear();
/// ```
final class HttpClientFactory {
  /// Creates a new, empty [HttpClientFactory].
  HttpClientFactory();

  static const String _defaultName = '';

  final List<void Function(HttpClientBuilder)> _defaultConfigs = [];
  final Map<String, _ClientRegistration> _registrations = {};
  final Map<Type, _TypedEntryBase> _typedEntries = {};

  // --------------------------------------------------------------------------
  // Default configuration
  // --------------------------------------------------------------------------

  /// Registers a [configure] callback applied to **every** client built by
  /// this factory.
  ///
  /// Multiple calls accumulate  each new configurator is appended to the
  /// existing list.  All cached clients are invalidated so the next
  /// [createClient] or [createTypedClient] call rebuilds them.
  ///
  /// ```dart
  /// factory
  ///   ..configureDefaults((b) => b.withDefaultHeader('Accept', 'application/json'))
  ///   ..configureDefaults((b) => b.withLogging());
  /// ```
  HttpClientFactory configureDefaults(
    void Function(HttpClientBuilder) configure,
  ) {
    _defaultConfigs.add(configure);
    for (final r in _registrations.values) {
      r.invalidate();
    }
    for (final e in _typedEntries.values) {
      e.invalidate();
    }
    return this;
  }

  // --------------------------------------------------------------------------
  // Named clients
  // --------------------------------------------------------------------------

  /// Registers (or extends) a named client configuration.
  ///
  /// The [configure] callback receives an [HttpClientBuilder] pre-loaded with
  /// all [configureDefaults] configurations.  Settings applied inside
  /// [configure] override defaults.
  ///
  /// Calling [addClient] with an existing [name] appends the new configurator
  /// to the existing list rather than replacing it.
  ///
  /// ```dart
  /// factory.addClient('api', (b) => b
  ///     .withBaseUri(Uri.parse('https://api.example.com'))
  ///     .withPolicy(Policy.retry(maxRetries: 3)));
  /// ```
  HttpClientFactory addClient(
    String name,
    void Function(HttpClientBuilder) configure,
  ) {
    _registrations
        .putIfAbsent(name, () => _ClientRegistration(name))
        .addConfig(configure);
    for (final e in _typedEntries.values) {
      if (e.clientName == name) e.invalidate();
    }
    return this;
  }

  /// Returns the [ResilientHttpClient] for [name], building and caching it on
  /// the first call.
  ///
  /// If no [addClient] registration exists for the **empty-string** default
  /// name, an empty client backed only by [configureDefaults] is auto-created.
  ///
  /// Throws [StateError] for any non-empty [name] that has not been registered.
  ///
  /// ```dart
  /// final client = factory.createClient('catalog');
  /// ```
  ResilientHttpClient createClient([String name = _defaultName]) {
    if (!_registrations.containsKey(name)) {
      if (name.isEmpty) {
        _registrations[name] = _ClientRegistration(name);
      } else {
        throw StateError(
          'HttpClientFactory: no client registered with name "$name". '
          'Call addClient("$name", ...) first.',
        );
      }
    }
    final reg = _registrations[name]!;
    return reg._cached ??= _buildForRegistration(reg);
  }

  // --------------------------------------------------------------------------
  // Typed clients
  // --------------------------------------------------------------------------

  /// Registers a typed client of type [T].
  ///
  /// [create] receives the underlying [ResilientHttpClient] (identified by
  /// [clientName]) and returns the domain-specific service object.
  ///
  /// Optionally provide a [configure] callback to configure the underlying
  /// named client in the same call.
  ///
  /// ```dart
  /// factory.addTypedClient<UserService>(
  ///   (client) => UserService(client),
  ///   clientName: 'users-api',
  ///   configure: (b) => b.withBaseUri(Uri.parse('https://users.svc/v1')),
  /// );
  /// ```
  HttpClientFactory addTypedClient<T extends Object>(
    T Function(ResilientHttpClient) create, {
    String clientName = _defaultName,
    void Function(HttpClientBuilder)? configure,
  }) {
    if (configure != null) addClient(clientName, configure);
    _typedEntries[T] = _TypedEntry<T>(clientName: clientName, factory: create);
    return this;
  }

  /// Returns the typed client of type [T], building and caching it on the
  /// first call.
  ///
  /// Throws [StateError] if [addTypedClient<T>] has not been called.
  ///
  /// ```dart
  /// final service = factory.createTypedClient<UserService>();
  /// ```
  T createTypedClient<T extends Object>() {
    final entry = _typedEntries[T];
    if (entry == null) {
      throw StateError(
        'HttpClientFactory: no typed client registered for type $T. '
        'Call addTypedClient<$T>() first.',
      );
    }
    final typed = entry as _TypedEntry<T>;
    return typed.getOrCreate(createClient(typed.clientName));
  }

  // --------------------------------------------------------------------------
  // Introspection
  // --------------------------------------------------------------------------

  /// Returns `true` if a named client with [name] has been registered.
  bool hasClient(String name) => _registrations.containsKey(name);

  /// The names of all explicitly registered named clients.
  Set<String> get registeredNames => Set.unmodifiable(_registrations.keys);

  /// The [Type]s of all registered typed clients.
  Set<Type> get registeredTypes => Set.unmodifiable(_typedEntries.keys);

  // --------------------------------------------------------------------------
  // Cache management
  // --------------------------------------------------------------------------

  /// Invalidates the cached client(s) for [name], forcing a rebuild on the
  /// next [createClient] call.
  ///
  /// When [name] is omitted, **all** cached clients and typed clients are
  /// invalidated.
  ///
  /// ```dart
  /// factory.invalidate('payments');  // rebuild 'payments' next call
  /// factory.invalidate();            // rebuild everything
  /// ```
  void invalidate([String? name]) {
    if (name != null) {
      _registrations[name]?.invalidate();
      for (final e in _typedEntries.values) {
        if (e.clientName == name) e.invalidate();
      }
    } else {
      for (final r in _registrations.values) {
        r.invalidate();
      }
      for (final e in _typedEntries.values) {
        e.invalidate();
      }
    }
  }

  /// Removes all registrations, configured defaults, and cached instances,
  /// returning the factory to freshly constructed state.
  void clear() {
    _defaultConfigs.clear();
    _registrations.clear();
    _typedEntries.clear();
  }

  /// Disposes all cached [ResilientHttpClient] instances, releasing their
  /// underlying HTTP connections.
  ///
  /// Only instances that were built with an internally-created [http.Client]
  /// (i.e. **not** via [HttpClientBuilder.withHttpClient]) will have their
  /// sockets closed.  Injected clients remain the caller's responsibility.
  ///
  /// Registrations and configurations are preserved; [createClient] will
  /// rebuild fresh instances if called after [dispose].
  void dispose() {
    for (final reg in _registrations.values) {
      reg._cached?.dispose();
      reg.invalidate();
    }
  }

  // --------------------------------------------------------------------------
  // Internal build
  // --------------------------------------------------------------------------

  ResilientHttpClient _buildForRegistration(_ClientRegistration reg) {
    final builder = HttpClientBuilder(reg.name);
    for (final cfg in _defaultConfigs) {
      cfg(builder);
    }
    for (final cfg in reg.configs) {
      cfg(builder);
    }
    return builder.build();
  }

  @override
  String toString() {
    final names = _registrations.keys
        .map((n) => n.isEmpty ? '(default)' : '"$n"')
        .join(', ');
    return 'HttpClientFactory(clients: [$names])';
  }
}
