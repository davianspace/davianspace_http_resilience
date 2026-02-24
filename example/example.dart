// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:logging/logging.dart';

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
///
/// Run with:
///   dart run example/example.dart
/// ============================================================

// Module-level factory instance for Example 2 (named-client registry pattern).
final _factory = HttpClientFactory();

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
      .withLogging()
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
          .withLogging(),
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
      .withLogging()
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
  print('\n[Example 9] Header redaction in logging');

  // Demonstrate that LoggingHandler can be configured with custom redaction
  print('  → Default redacted headers:');
  print('    - authorization');
  print('    - proxy-authorization');
  print('    - cookie');
  print('    - set-cookie');
  print('    - x-api-key');
  print('  → Custom redacted headers can be added via the constructor:');
  print('    LoggingHandler(');
  print('      logHeaders: true,');
  print("      redactedHeaders: {'authorization', 'x-custom-secret'},");
  print('    )');
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
  print('  Companion package: davianspace_http_ratelimit ^1.0.0');
  print('');
  print('  pubspec.yaml:');
  print('    dependencies:');
  print('      davianspace_http_resilience: ^1.0.2');
  print('      davianspace_http_ratelimit:  ^1.0.0');
  print('');
  print('  Token Bucket — burst up to 200, sustain 100 req/s:');
  print("    final client = HttpClientBuilder('my-api')");
  print("        .withBaseUri(Uri.parse('https://api.example.com'))");
  print(
    '        .withLogging()                 // logs first (captures full picture)',
  );
  print(
    '        .withRateLimit(RateLimitPolicy(  // \u2190 extension from companion package',
  );
  print('          limiter: TokenBucketRateLimiter(');
  print('            capacity: 200,');
  print('            refillAmount: 100,');
  print('            refillInterval: Duration(seconds: 1),');
  print('          ),');
  print('          acquireTimeout: Duration(milliseconds: 500),');
  print('          respectServerHeaders: true,');
  print('        ))');
  print(
    '        .withRetry(RetryPolicy.exponential(maxRetries: 3))  // retried reqs also rate-limited',
  );
  print(
    '        .withCircuitBreaker(CircuitBreakerPolicy(circuitName: \'api\'))',
  );
  print('        .build();');
  print('');
  print('  On exhaustion: RateLimitExceededException is thrown.');
  print('  Six algorithms: TokenBucket, FixedWindow, SlidingWindow,');
  print('                  SlidingWindowLog, LeakyBucket, ConcurrencyLimiter.');
  print('  For runnable examples of each algorithm, see:');
  print('    davianspace_http_ratelimit/example/example.dart');
}

// ─────────────────────────────────────────────────────────────
// Helpers & custom handler
// ─────────────────────────────────────────────────────────────

void _configureLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (r) => print('[${r.loggerName}] ${r.level.name}: ${r.message}'),
  );
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
