// ignore_for_file: avoid_print
import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:logging/logging.dart';

/// ============================================================
/// davianspace_http_resilience — Full Usage Example
/// ============================================================
///
/// This example demonstrates:
///
///  1.  Basic fluent client construction with all policies
///  2.  Named client registration via HttpClientFactory
///  3.  Manual pipeline construction with custom handlers
///  4.  RetryPredicates composition
///  5.  CancellationToken usage
///  6.  HttpResponse extension helpers
///  7.  CircuitBreakerRegistry inspection
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
  print('\nAll examples completed.');
}

// ─────────────────────────────────────────────────────────────
// 1. Basic client with all policies
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
    // HttpStatusException is an HttpResilienceException — catch it first since
    // it is the more specific type.
    print('  ✗ HTTP error: $e');
  } on HttpResilienceException catch (e) {
    print('  ✗ Resilience error: $e');
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
// 3. Manual pipeline with a custom handler
// ─────────────────────────────────────────────────────────────

Future<void> _example3CustomHandler() async {
  print('\n[Example 3] Custom DelegatingHandler in the pipeline');

  // Use HttpClientBuilder directly — lightweight, no factory needed.
  final client = HttpClientBuilder('custom')
      .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
      .addHandler(_CorrelationIdHandler())
      .withLogging()
      .build();

  final response = await client.get(Uri.parse('/users/1'));
  print(
    '  → X-Correlation-Id echoed: '
    '${response.headers['x-correlation-id'] ?? "(not echoed by server — check request)"}',
  );
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
// Helpers & custom handler
// ─────────────────────────────────────────────────────────────

void _configureLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (r) => print('[${r.loggerName}] ${r.level.name}: ${r.message}'),
  );
}

/// Injects a unique correlation ID into every outgoing request.
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
