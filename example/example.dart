// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:davianspace_logging/davianspace_logging.dart';

/// ============================================================
/// davianspace_http_resilience — Production Usage Examples
/// ============================================================
///
/// This example demonstrates enterprise-ready patterns:
///
///  1. Full-stack resilient client with all policies
///  2. Named client factory registry
///  3. Custom DelegatingHandler (auth / correlation)
///  4. CancellationToken usage
///  5. RetryPredicates composition
///  6. Configuration-driven policies (JSON)
///  7. Per-request streaming override
///  8. Circuit breaker health monitoring
///  9. Header-redacted security logging
///  10. Rate limiter integration (davianspace_http_ratelimit companion)
///  11. Map body auto-encoding (JSON)
///  12. Transport-agnostic policy engine
///  13. Observability & event hub
///  14. Error handling patterns
///  15. Fallback with event hub integration
///
/// Run with:
///   dart run example/example.dart
/// ============================================================

// Module-level factory instance for Example 2 (named-client registry pattern).
final _factory = HttpClientFactory();
// Module-level logger factory for structured HTTP logging.
late LoggerFactory _logFactory;

void main() async {
  _configureLogging();

  await _example1BasicClient();
  await _example2NamedClientFactory();
  await _example3CustomHandler();
  _example4CancellationToken();
  _example5RetryPredicates();
  _example6ConfigDrivenPolicies();
  _example7PerRequestStreaming();
  _example8CircuitBreakerHealth();
  _example9HeaderRedaction();
  _example10RateLimiterIntegration();
  await _example11MapBodyAutoEncoding();
  _example12TransportAgnosticPolicies();
  _example13ObservabilityEventHub();
  await _example14ErrorHandling();
  _example15FallbackWithEventHub();
  print('\nAll examples completed.');
}

// ─────────────────────────────────────────────────────────────
// 1. Full-stack resilient client
// ─────────────────────────────────────────────────────────────

Future<void> _example1BasicClient() async {
  print('\n[Example 1] Resilient client with full policy stack');

  final client = HttpClientBuilder('jsonplaceholder')
      .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
      .withDefaultHeader('Accept', 'application/json')
      .withLogging(logger: _logFactory.createLogger('davianspace.http'))
      .withRetry(
        RetryPolicy.exponential(
          maxRetries: 3,
          baseDelay: const Duration(milliseconds: 100),
          useJitter: true,
          shouldRetry:
              RetryPredicates.serverErrors.or(RetryPredicates.networkErrors),
        ),
      )
      .withCircuitBreaker(
        const CircuitBreakerPolicy(
          circuitName: 'jsonplaceholder',
        ),
      )
      .withTimeout(
        const TimeoutPolicy(timeout: Duration(seconds: 10)),
      )
      .withBulkhead(
        const BulkheadPolicy(maxQueueDepth: 50),
      )
      .build();

  try {
    final response = await client
        .get(Uri.parse('/todos/1'))
        .then((HttpResponse r) => r.ensureSuccess());

    final json = response.bodyAsJsonMap;
    print('  → title: ${json?['title']}');
    print('  → duration: ${response.duration.inMilliseconds}ms');
  } on HttpStatusException catch (e) {
    print('  ✗ HTTP error: $e');
  } on HttpResilienceException catch (e) {
    print('  ✗ Resilience error: $e');
  } finally {
    client.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
// 2. Named client factory registry
// ─────────────────────────────────────────────────────────────

Future<void> _example2NamedClientFactory() async {
  print('\n[Example 2] Named client factory');

  // Register once (e.g. in main() or a DI bootstrapper).
  if (!_factory.hasClient('posts-api')) {
    _factory.addClient(
      'posts-api',
      (b) => b
          .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
          .withRetry(RetryPolicy.constant(maxRetries: 2))
          .withLogging(logger: _logFactory.createLogger('davianspace.http')),
    );
  }

  // Resolve anywhere in the application.
  final client = _factory.createClient('posts-api');

  try {
    final response = await client.get(Uri.parse('/posts/1'));
    print('  → status: ${response.statusCode}');
    final map = response.bodyAsJsonMap;
    print('  → id: ${map?["id"]}, userId: ${map?["userId"]}');
  } on Exception catch (e) {
    print('  ✗ $e');
  } finally {
    _factory.clear(); // cleanup between examples
  }
}

// ─────────────────────────────────────────────────────────────
// 3. Custom handler (correlation ID injection)
// ─────────────────────────────────────────────────────────────

Future<void> _example3CustomHandler() async {
  print('\n[Example 3] Custom DelegatingHandler in the pipeline');

  final client = HttpClientBuilder('custom')
      .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
      .addHandler(_CorrelationIdHandler())
      .withLogging(logger: _logFactory.createLogger('davianspace.http'))
      .build();

  try {
    final response = await client.get(Uri.parse('/users/1'));
    print(
      '  → X-Correlation-Id echoed: '
      '${response.headers['x-correlation-id'] ?? "(not echoed by server — check request)"}',
    );
  } finally {
    client.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
// 4. CancellationToken
// ─────────────────────────────────────────────────────────────

void _example4CancellationToken() {
  print('\n[Example 4] CancellationToken');

  final token = CancellationToken();
  print('  isCancelled before: ${token.isCancelled}');
  token.cancel('user pressed back');
  print('  isCancelled after:  ${token.isCancelled}');
  print('  reason: ${token.reason}');

  try {
    token.throwIfCancelled();
  } on CancellationException catch (e) {
    print('  Caught: $e');
  }
}

// ─────────────────────────────────────────────────────────────
// 5. RetryPredicates composition
// ─────────────────────────────────────────────────────────────

void _example5RetryPredicates() {
  print('\n[Example 5] RetryPredicates composition');

  final predicate = RetryPredicates.serverErrors
      .or(RetryPredicates.rateLimitAndServiceUnavailable);

  final ctx = HttpContext(
    request: HttpRequest(
      method: HttpMethod.get,
      uri: Uri.parse('https://example.com'),
    ),
  );

  print(
    '  Should retry 503: '
    '${predicate(HttpResponse(statusCode: 503), null, ctx)}',
  );
  print(
    '  Should retry 429: '
    '${predicate(HttpResponse(statusCode: 429), null, ctx)}',
  );
  print(
    '  Should retry 404: '
    '${predicate(HttpResponse(statusCode: 404), null, ctx)}',
  );
  print(
    '  Should retry exception: '
    '${predicate(null, Exception('network'), ctx)}',
  );
}

// ─────────────────────────────────────────────────────────────
// 6. Configuration-driven policies (JSON)
// ─────────────────────────────────────────────────────────────

void _example6ConfigDrivenPolicies() {
  print('\n[Example 6] Configuration-driven policies from JSON');

  const configJson = '''
  {
    "Resilience": {
      "Retry": {
        "MaxRetries": 3,
        "Backoff": { "Type": "exponential", "BaseMs": 200, "UseJitter": true }
      },
      "Timeout": { "Seconds": 10 },
      "CircuitBreaker": {
        "CircuitName": "config-demo",
        "FailureThreshold": 5,
        "BreakSeconds": 30
      },
      "BulkheadIsolation": {
        "MaxConcurrentRequests": 20,
        "MaxQueueSize": 50
      },
      "Hedging": {
        "HedgeAfterMs": 300,
        "MaxHedgedAttempts": 2
      },
      "Fallback": {
        "StatusCodes": [500, 502, 503, 504]
      }
    }
  }
  ''';

  const loader = ResilienceConfigLoader();
  const binder = ResilienceConfigBinder();

  final config = loader.load(configJson);
  print('  → Config loaded: isEmpty=${config.isEmpty}');
  print('  → Retry: ${config.retry}');
  print('  → Timeout: ${config.timeout}');
  print('  → CircuitBreaker: ${config.circuitBreaker}');
  print('  → BulkheadIsolation: ${config.bulkheadIsolation}');
  print('  → Hedging: ${config.hedging}');
  print('  → Fallback: ${config.fallback}');

  // Build a composed pipeline from all configured sections
  final pipeline = binder.buildPipeline(config);
  print('  → Pipeline built: $pipeline');

  // Build individual policies
  if (config.hedging != null) {
    final hedging = binder.buildHedging(config.hedging!);
    print('  → Hedging policy: $hedging');
  }

  if (config.fallback != null) {
    final fallback = binder.buildFallbackPolicy(
      config.fallback!,
      fallbackAction: (ctx, err, st) async => HttpResponse(
        statusCode: 200,
        body: utf8.encode('{"offline": true}'),
      ),
    );
    print('  → Fallback policy: $fallback');
  }

  // Register all into the policy registry
  PolicyRegistry.instance.loadFromConfig(config, prefix: 'demo');
  print('  → Policies registered in PolicyRegistry with prefix "demo"');

  // Cleanup
  pipeline.dispose();
}

// ─────────────────────────────────────────────────────────────
// 7. Per-request streaming override
// ─────────────────────────────────────────────────────────────

void _example7PerRequestStreaming() {
  print('\n[Example 7] Per-request streaming override');

  // Demonstrate the metadata key (no actual HTTP call needed)
  final request = HttpRequest(
    method: HttpMethod.get,
    uri: Uri.parse('https://api.example.com/large-file'),
    metadata: {HttpRequest.streamingKey: true},
  );

  final isStreaming =
      request.metadata[HttpRequest.streamingKey] as bool? ?? false;
  print('  → Metadata key: ${HttpRequest.streamingKey}');
  print('  → Request streaming override: $isStreaming');

  // Force-buffer example
  final bufferedRequest = HttpRequest(
    method: HttpMethod.get,
    uri: Uri.parse('https://api.example.com/small-resource'),
    metadata: {HttpRequest.streamingKey: false},
  );

  final isBuffered =
      bufferedRequest.metadata[HttpRequest.streamingKey] as bool? ?? true;
  print('  → Force-buffer override: ${!isBuffered}');
}

// ─────────────────────────────────────────────────────────────
// 8. Circuit breaker health monitoring
// ─────────────────────────────────────────────────────────────

void _example8CircuitBreakerHealth() {
  print('\n[Example 8] Circuit breaker health monitoring');

  final registry = CircuitBreakerRegistry.instance;

  // Check if we have circuits from earlier examples
  final names = registry.circuitNames.toList();
  print('  → Registered circuits: $names');

  // registry.isHealthy checks ALL circuits (getter, not a method).
  print('  → All circuits healthy: ${registry.isHealthy}');

  // Use snapshot for per-circuit state details.
  final snap = registry.snapshot;
  for (final entry in snap.entries) {
    print('  → Circuit "${entry.key}": state=${entry.value}');
  }

  if (names.isEmpty) {
    print('  → (No circuits registered — run Example 1 first)');
  }
}

// ─────────────────────────────────────────────────────────────
// 9. Header-redacted security logging
// ─────────────────────────────────────────────────────────────

void _example9HeaderRedaction() {
  print('\n[Example 9] Header redaction in structured logging');

  // Build a LoggingHandler that emits structured JSON and redacts sensitive
  // headers.  The default redaction set covers Authorization, Cookie,
  // Set-Cookie, Proxy-Authorization, and X-Api-Key.  Supply a custom set to
  // add or narrow that list.
  final defaultHandler = LoggingHandler(
    structured: true,
    logHeaders: true,
    // Default redaction set: authorization, cookie, set-cookie,
    // proxy-authorization, x-api-key.
  );

  final restrictedHandler = LoggingHandler(
    structured: true,
    logHeaders: true,
    // Organisation-specific additions on top of the defaults.
    redactedHeaders: const {
      'authorization',
      'cookie',
      'x-api-key',
      'x-internal-token',
      'x-impersonation-user',
    },
    uriSanitizer: (uri) {
      // Strip both query params and the fragment before logging.
      return uri.replace(queryParameters: const {}, fragment: '').toString();
    },
  );

  // Integrate into the builder pipeline with addHandler().
  final client = HttpClientBuilder()
      .withBaseUri(Uri.parse('https://api.example.com'))
      .addHandler(defaultHandler)
      .build();

  final restrictedClient = HttpClientBuilder()
      .withBaseUri(Uri.parse('https://internal.api.example.com'))
      .addHandler(restrictedHandler)
      .build();

  print('  Default handler — redacts: authorization, cookie, set-cookie,'
      ' proxy-authorization, x-api-key');
  print('  Default client ready    : ${client.runtimeType}');
  print('  Restricted client ready : ${restrictedClient.runtimeType}');

  client.dispose();
  restrictedClient.dispose();
}

// ─────────────────────────────────────────────────────────────
// 10. Rate limiter integration (davianspace_http_ratelimit companion)
// ─────────────────────────────────────────────────────────────

/// Shows how to add client-side rate limiting to any [HttpClientBuilder]
/// pipeline using the companion package.
///
/// The companion package ships a `HttpClientBuilderRateLimitExtension` that
/// adds `.withRateLimit(RateLimitPolicy)` directly to [HttpClientBuilder],
/// so all six rate-limiting algorithms slot seamlessly into the fluent API.
void _example10RateLimiterIntegration() {
  print('\n[Example 10] Rate limiter integration');

  // This example shows the resilience-only pipeline that anchors into a full
  // retry + circuit-breaker chain.  Add davianspace_http_ratelimit to pubspec
  // and call .withRateLimit(policy) between .withLogging() and .withRetry()
  // to cap outbound throughput before resilience policies fire.
  //
  // pubspec.yaml:
  //   dependencies:
  //     davianspace_http_resilience: ^1.0.2
  //     davianspace_http_ratelimit:  ^1.0.0
  //
  // Full pipeline with rate limiting (token bucket — 100 req/s, burst 200):
  //
  //   final client = HttpClientBuilder('my-api')
  //       .withBaseUri(Uri.parse('https://api.example.com'))
  //       .withLogging()
  //       .withRateLimit(RateLimitPolicy(        // ← companion extension
  //         limiter: TokenBucketRateLimiter(
  //           capacity: 200,
  //           refillAmount: 100,
  //           refillInterval: Duration(seconds: 1),
  //         ),
  //         acquireTimeout: Duration(milliseconds: 500),
  //         respectServerHeaders: true,
  //         onRejected: (ctx, e) => log.warning('rate-limited: $e'),
  //       ))
  //       .withRetry(RetryPolicy.exponential(maxRetries: 3))
  //       .withCircuitBreaker(const CircuitBreakerPolicy(circuitName: 'my-api'))
  //       .build();
  //
  // Policy order matters: logging captures the full picture first, rate
  // limiting gates throughput, then retry handles transient failures, and
  // the circuit breaker trips on sustained error rates.

  // Build the resilience-only portion to confirm it compiles independently.
  final baseClient = HttpClientBuilder()
      .withBaseUri(Uri.parse('https://api.example.com'))
      .withLogging(logger: _logFactory.createLogger('davianspace.http'))
      .withRetry(RetryPolicy.exponential(maxRetries: 3))
      .withCircuitBreaker(const CircuitBreakerPolicy(circuitName: 'my-api'))
      .build();

  print('  Resilience-only pipeline built: ${baseClient.runtimeType}');
  print('  Add davianspace_http_ratelimit and insert .withRateLimit() after'
      ' .withLogging() to gate outbound throughput.');

  baseClient.dispose();
}

// ─────────────────────────────────────────────────────────────
// 11. Map body auto-encoding (JSON)
// ─────────────────────────────────────────────────────────────

/// Demonstrates the automatic JSON encoding of `Map<String, dynamic>` bodies.
///
/// In v1.0.4, `ResilientHttpClient` verb helpers (`post`, `put`, `patch`)
/// detect `Map<String, dynamic>` and `Map<String, Object?>` bodies and
/// automatically call `jsonEncode()` + set `Content-Type: application/json`.
Future<void> _example11MapBodyAutoEncoding() async {
  print('\n[Example 11] Map body auto-encoding (JSON)');

  final client = HttpClientBuilder('auto-json')
      .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
      .withLogging(logger: _logFactory.createLogger('davianspace.http'))
      .withRetry(RetryPolicy.constant(maxRetries: 1))
      .build();

  try {
    // Pass a Map directly — no jsonEncode() or Content-Type header needed!
    final response = await client.post(
      Uri.parse('/posts'),
      body: {
        'title': 'Auto-encoded post',
        'body': 'This map was automatically JSON-encoded',
        'userId': 1,
      },
    );

    final json = response.ensureSuccess().bodyAsJsonMap;
    print('  → Created post id: ${json?['id']}');
    print('  → Status: ${response.statusCode}');

    // String bodies still work as before
    final stringResponse = await client.post(
      Uri.parse('/posts'),
      body: jsonEncode({'title': 'Manual encode', 'userId': 1}),
      headers: {'Content-Type': 'application/json'},
    );
    print('  → String body status: ${stringResponse.statusCode}');
  } on HttpStatusException catch (e) {
    print('  ✗ HTTP error: $e');
  } finally {
    client.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
// 12. Transport-agnostic policy engine
// ─────────────────────────────────────────────────────────────

/// Demonstrates using resilience policies independent of HTTP.
///
/// `Policy.wrap` and `ResiliencePipelineBuilder` work with any async
/// operation — database calls, gRPC, file I/O, etc.
void _example12TransportAgnosticPolicies() {
  print('\n[Example 12] Transport-agnostic policy engine');

  // Build a composite policy from the Policy factory
  final policy = Policy.wrap([
    Policy.retry(maxRetries: 3),
    Policy.timeout(const Duration(seconds: 5)),
    Policy.bulkheadIsolation(maxConcurrentRequests: 15),
  ]);

  final policyWrap = policy as PolicyWrap;
  print('  → Policy created: ${policy.runtimeType}');
  print('  → Contains ${policyWrap.policies.length} nested policies');

  for (final p in policyWrap.policies) {
    print('    • ${p.runtimeType}');
  }

  // Also available via the fluent builder
  final pipeline = ResiliencePipelineBuilder()
      .addPolicy(RetryResiliencePolicy(
        maxRetries: 2,
        backoff: const ConstantBackoff(Duration(milliseconds: 100)),
        onRetry: (attempt, exception) {
          print('  → Retry attempt $attempt: $exception');
        },
      ),)
      .addPolicy(
        const TimeoutResiliencePolicy(
           Duration(seconds: 3),
        ),
      )
      .build();

  print('  → Fluent pipeline: ${pipeline.runtimeType}');

  // Usage example (not executed — just demonstrates the API):
  //   final result = await policy.execute(() => myDatabase.query('...'));
  //   final rows  = await pipeline.execute(() => grpcClient.fetchAll());

  policy.dispose();
  pipeline.dispose();
}

// ─────────────────────────────────────────────────────────────
// 13. Observability & event hub
// ─────────────────────────────────────────────────────────────

/// Demonstrates subscribing to resilience lifecycle events via the event hub.
///
/// The `ResilienceEventHub` provides both type-safe and catch-all subscriptions
/// for retry, circuit breaker, timeout, fallback, and bulkhead events.
void _example13ObservabilityEventHub() {
  print('\n[Example 13] Observability & event hub');

  final hub = ResilienceEventHub();

  // Type-safe subscription for specific event types
  hub.on<RetryEvent>((event) {
    print('  → [RetryEvent] attempt=${event.attemptNumber}');
  });

  hub.on<CircuitOpenEvent>((event) {
    print('  → [CircuitOpenEvent] circuit=${event.circuitName}');
  });

  hub.on<TimeoutEvent>((event) {
    print('  → [TimeoutEvent] $event');
  });

  hub.on<FallbackEvent>((event) {
    print('  → [FallbackEvent] $event');
  });

  hub.on<BulkheadRejectedEvent>((event) {
    print('  → [BulkheadRejectedEvent] $event');
  });

  // Catch-all subscription for logging / diagnostics
  hub.onAny((event) {
    print('  → [ANY] ${event.runtimeType}');
  });

  // Emit synthetic events to show the subscriptions in action
  hub.emit(RetryEvent(
    attemptNumber: 1,
    delay: const Duration(milliseconds: 200),
    maxAttempts: 3,
  ),);
  hub.emit(CircuitOpenEvent(
    circuitName: 'demo-circuit',
    previousState: CircuitState.closed,
    consecutiveFailures: 5,
  ),);
  hub.emit(FallbackEvent());

  // Introspection
  print('  → Active listeners: ${hub.listenerCount}');
  print('  → Has listeners: ${hub.isNotEmpty}');

  hub.clear();
  print('  → Cleared all listeners');
}

// ─────────────────────────────────────────────────────────────
// 14. Error handling patterns
// ─────────────────────────────────────────────────────────────

/// Demonstrates the structured exception hierarchy.
///
/// All resilience exceptions extend `HttpResilienceException`, enabling
/// both fine-grained and catch-all error handling.
Future<void> _example14ErrorHandling() async {
  print('\n[Example 14] Error handling patterns');

  final client = HttpClientBuilder('error-demo')
      .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
      .withRetry(RetryPolicy.constant(
        maxRetries: 1,
      ),)
      .withCircuitBreaker(const CircuitBreakerPolicy(
        circuitName: 'error-demo',
        failureThreshold: 10, // high threshold so we don't trip
      ),)
      .withTimeout(const TimeoutPolicy(timeout: Duration(seconds: 10)))
      .build();

  // Demonstrate HttpStatusException from ensureSuccess()
  try {
    final response = await client.get(Uri.parse('/posts/99999'));
    response.ensureSuccess(); // throws if non-2xx
    print('  → Success: ${response.bodyAsString}');
  } on HttpStatusException catch (e) {
    print('  → Caught HttpStatusException: status=${e.statusCode}');
  }

  // Demonstrate CancellationException
  try {
    final token = CancellationToken();
    token.cancel('demo cancellation');
    token.throwIfCancelled();
  } on CancellationException catch (e) {
    print('  → Caught CancellationException: reason=${e.reason}');
  }

  // Demonstrate exception hierarchy via try/catch:
  // HttpResilienceException is itself an Exception
  try {
    throw const HttpResilienceException('hierarchy demo');
  } on Exception catch (e) {
    print('  → HttpResilienceException caught as Exception (${e.runtimeType})');
  }

  // HttpTimeoutException extends HttpResilienceException
  try {
    throw HttpTimeoutException(timeout: const Duration(seconds: 5));
  } on HttpResilienceException catch (e) {
    print('  → HttpTimeoutException caught as HttpResilienceException '
        '(${e.runtimeType})');
  }

  client.dispose();
}

// ─────────────────────────────────────────────────────────────
// 15. Fallback with event hub integration
// ─────────────────────────────────────────────────────────────

/// Demonstrates FallbackPolicy with `eventHub` for error reporting.
///
/// In v1.0.4, `FallbackPolicy` can accept an optional `ResilienceEventHub`.
/// If the user's fallback callback throws, the error is caught and emitted
/// as a `FallbackCallbackErrorEvent` instead of being silently swallowed.
void _example15FallbackWithEventHub() {
  print('\n[Example 15] Fallback with event hub integration');

  final hub = ResilienceEventHub();

  // Listen for fallback callback errors
  hub.on<FallbackCallbackErrorEvent>((event) {
    print('  → [FallbackCallbackErrorEvent]');
    print('    original error : ${event.originalError}');
    print('    callback error : ${event.callbackError}');
  });

  // Build a fallback policy that reports errors to the event hub
  final fallback = FallbackPolicy(
    eventHub: hub,
    fallbackAction: (context, error, stackTrace) async => HttpResponse(
      statusCode: 200,
      body: utf8.encode('{"cached": true, "source": "fallback"}'),
    ),
    shouldHandle: (response, exception, context) {
      if (exception != null) return true;
      return response != null &&
          [500, 502, 503, 504].contains(response.statusCode);
    },
  );

  print('  → FallbackPolicy created with eventHub');
  print('  → shouldHandle 503: ${fallback.shouldHandle!(HttpResponse(statusCode: 503), null, HttpContext(request: HttpRequest(method: HttpMethod.get, uri: Uri.parse("https://example.com"))))}');
  print('  → shouldHandle 200: ${fallback.shouldHandle!(HttpResponse(statusCode: 200), null, HttpContext(request: HttpRequest(method: HttpMethod.get, uri: Uri.parse("https://example.com"))))}');

  hub.clear();
}

// ─────────────────────────────────────────────────────────────
// Helpers & custom handler
// ─────────────────────────────────────────────────────────────

void _configureLogging() {
  _logFactory = LoggingBuilder()
      .addConsole()
      .setMinimumLevel(LogLevel.info)
      .build();
}

/// Injects a unique correlation ID into every outgoing request.
///
/// This is a common enterprise pattern for distributed tracing. Each request
/// gets a unique identifier that can be tracked across microservices.
final class _CorrelationIdHandler extends DelegatingHandler {
  _CorrelationIdHandler();

  int _counter = 0;

  @override
  Future<HttpResponse> send(HttpContext context) {
    final id = 'req-${++_counter}-${DateTime.now().millisecondsSinceEpoch}';
    context.updateRequest(
      context.request.withHeader('X-Correlation-Id', id),
    );
    context.setProperty('correlationId', id);
    return innerHandler.send(context);
  }
}
