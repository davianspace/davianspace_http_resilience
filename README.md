# davianspace_http_resilience

[![pub version](https://img.shields.io/pub/v/davianspace_http_resilience.svg)](https://pub.dev/packages/davianspace_http_resilience)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue.svg)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Tests](https://img.shields.io/badge/tests-788%20passing-brightgreen)

A **production-ready** Dart/Flutter HTTP resilience library inspired by
[Microsoft.Extensions.Http](https://learn.microsoft.com/en-us/dotnet/core/extensions/httpclient-factory)
and [Microsoft.Extensions.Http.Resilience](https://learn.microsoft.com/en-us/dotnet/core/resilience/http-resilience)
with [Polly](https://github.com/App-vNext/Polly)-style policies.

## Features

| Feature | Description |
|---------|-------------|
| **Composable middleware pipeline** | Chain any number of handlers in a type-safe, ordered pipeline |
| **Retry policy** | Constant, linear, and exponential back-off with optional full jitter |
| **Circuit breaker** | Closed / Open / Half-Open state machine with configurable thresholds |
| **Timeout policy** | Per-attempt or total-operation deadlines |
| **Bulkhead (concurrency limiter)** | Cap parallel requests + queue depth with back-pressure |
| **Bulkhead isolation** | Semaphore-based isolation with Completer-signalling, live metrics and rejection callbacks |
| **Resilience policy engine** | `Policy` factory + `PolicyWrap` for composable, transport-agnostic resilience logic |
| **Configuration-driven policies** | `ResilienceConfigLoader` + `JsonStringConfigSource` to bind policies from JSON at runtime |
| **Fluent builder DSL** | `FluentHttpClientBuilder` for expressive, step-by-step client construction |
| **Structured logging** | Zero-dependency logging via `package:logging` |
| **Typed HTTP client** | Ergonomic `get` / `post` / `put` / `patch` / `delete` verbs |
| **Named client registry** | `HttpClientFactory` for shared, lifecycle-managed clients |
| **Cancellation support** | `CancellationToken` for cooperative cancellation across the pipeline |
| **Response extensions** | `ensureSuccess()`, `bodyAsString`, `bodyAsJsonMap`, `bodyAsJsonList` |
| **Retry predicate DSL** | Composable `RetryPredicates` with `.or()` / `.and()` combinators |

---

## Installation

```yaml
dependencies:
  davianspace_http_resilience: ^1.0.0
```

```
dart pub get
```

---

## Quick Start

### Option A — Fluent factory (recommended for application clients)

```dart
import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';

void main() async {
  final client = HttpClientFactory.create('my-api')
      .withBaseUri(Uri.parse('https://api.example.com/v1'))
      .withDefaultHeader('Accept', 'application/json')
      .withLogging()
      .withRetry(RetryPolicy.exponential(
          maxRetries: 3,
          baseDelay: Duration(milliseconds: 200),
          useJitter: true,
      ))
      .withCircuitBreaker(CircuitBreakerPolicy(
          circuitName: 'my-api',
          failureThreshold: 5,
          breakDuration: Duration(seconds: 30),
      ))
      .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10)))
      .withBulkhead(BulkheadPolicy(maxConcurrency: 20, maxQueueDepth: 100))
      .build();

  final body = await client
      .get(Uri.parse('/users/42'))
      .then((r) => r.ensureSuccess().bodyAsJsonMap);

  print(body);
}
```

### Option B — Lightweight builder (tests, scripts, one-off clients)

```dart
final client = HttpClientBuilder('catalog')
    .withRetry(RetryPolicy.constant(maxRetries: 2))
    .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 5)))
    .build();

final response = await client.get(Uri.parse('https://api.example.com/items'));
print(response.bodyAsString);
```

---

## Architecture

```
Application code
      │
      ├── ResilienceConfigLoader  ← bind policies from JSON / env at runtime
      │         │
      │    JsonStringConfigSource / custom IConfigSource
      │
      ▼
HttpClientFactory  (named registry)   HttpClientBuilder  (lightweight)
      │                                       │
      └───────────────┬───────────────────────┘
                      ▼
            ResilientHttpClient    ← get / post / put / patch / delete
                      │
                      ▼
           HttpHandler pipeline    ← ordered chain
     ┌─────────────────────────────────────────────┐
     │  LoggingHandler          (outermost)        │
     │  RetryHandler                               │
     │  CircuitBreakerHandler                      │
     │  TimeoutHandler                             │
     │  BulkheadHandler / BulkheadIsolationHandler │
     │  TerminalHandler         (innermost — I/O)  │
     └─────────────────────────────────────────────┘
                      │
                      ▼
              package:http  (http.Client)

── Policy engine (transport-agnostic) ──────────────────────────────────────
  Policy.retry / Policy.circuitBreaker / Policy.timeout
  Policy.bulkhead / Policy.bulkheadIsolation / Policy.wrap
  ResiliencePipelineBuilder — composes policies into an execution pipeline
```

### Pipeline execution order

Each handler implements the single method:

```dart
Future<HttpResponse> send(HttpContext context);
```

Handlers are linked via `DelegatingHandler.innerHandler`.  The outermost
handler executes first and the `TerminalHandler` performs the actual network
call.

### Key Abstractions

```
HttpHandler ──────────────────► abstract base
    │
    └── DelegatingHandler ──►  middleware base (has innerHandler)
            │
            ├── RetryHandler
            ├── CircuitBreakerHandler
            ├── TimeoutHandler
            ├── BulkheadHandler
            ├── BulkheadIsolationHandler
            └── LoggingHandler

HttpRequest   ──► immutable outgoing request model
HttpResponse  ──► immutable response model
HttpContext   ──► mutable per-request state bag (flows through pipeline)

RetryPolicy                ──► constant / linear / exponential back-off config
CircuitBreakerPolicy       ──► threshold + break-duration config
TimeoutPolicy              ──► per-attempt deadline config
BulkheadPolicy             ──► concurrency + queue-depth config
BulkheadIsolationPolicy    ──► semaphore-based isolation with rejection callbacks

Policy                     ──► factory for transport-agnostic resilience policies
PolicyWrap                 ──► composes multiple IResiliencePolicy into one
ResiliencePipelineBuilder  ──► fluent builder for PolicyWrap

ResilienceConfigLoader     ──► loads policy config from IConfigSource
JsonStringConfigSource     ──► JSON string implementation of IConfigSource

HttpClientFactory    ──► named client registry (application-scoped)
HttpClientBuilder    ──► lightweight single-client builder
ResilientHttpClient  ──► high-level HTTP verb API backed by the pipeline
```

---

## Usage

### Retry policy

```dart
// Exponential back-off with full jitter, retrying only on 5xx + exceptions
final policy = RetryPolicy.exponential(
  maxRetries: 4,
  baseDelay: Duration(milliseconds: 200),
  maxDelay: Duration(seconds: 30),
  useJitter: true,
  shouldRetry: RetryPredicates.serverErrors.or(RetryPredicates.networkErrors),
);
```

### Circuit breaker

```dart
final policy = CircuitBreakerPolicy(
  circuitName: 'payments',   // shared across all clients with this name
  failureThreshold: 5,       // 5 consecutive failures trips the breaker
  successThreshold: 2,       // 2 successes in half-open state to close
  breakDuration: Duration(seconds: 30),
);
```

### Custom handler

```dart
final class AuthHandler extends DelegatingHandler {
  AuthHandler(this._tokenProvider) : super.create();

  final Future<String> Function() _tokenProvider;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    final token = await _tokenProvider();
    context.updateRequest(
      context.request.withHeader('Authorization', 'Bearer $token'),
    );
    return innerHandler.send(context);
  }
}
```

### Named client factory

```dart
// Register once (e.g. in your DI container / main())
HttpClientFactory.register(
  'catalog',
  HttpClientFactory.create('catalog')
      .withBaseUri(Uri.parse('https://catalog.internal/v1'))
      .withRetry(RetryPolicy.exponential(maxRetries: 3))
      .build(),
);

// Resolve anywhere in the app
final client = HttpClientFactory.resolve('catalog');
```

### Cancellation

```dart
final token = CancellationToken();

// Cancel from UI or lifecycle event
onDispose: () => token.cancel('widget disposed'),

// Pass to a context
final context = HttpContext(
  request: HttpRequest(method: HttpMethod.get, uri: uri),
  cancellationToken: token,
);
final response = await pipeline.send(context);
```

### Response helpers

```dart
final response = await client.post(
  Uri.parse('/orders'),
  body: jsonEncode(order),
  headers: {'Content-Type': 'application/json'},
);

// Throws HttpStatusException for non-2xx
final map = response.ensureSuccess().bodyAsJsonMap;
final list = response.ensureSuccess().bodyAsJsonList;
final text = response.bodyAsString;
```

### Bulkhead isolation

`BulkheadIsolationPolicy` provides fine-grained isolation with rejection
callbacks and live slot metrics:

```dart
final policy = BulkheadIsolationPolicy(
  maxConcurrentRequests: 10,
  maxQueueSize: 20,
  queueTimeout: Duration(seconds: 5),
  onRejected: (reason) =>
      print('Rejected: $reason'),        // queueFull or queueTimeout
);

final client = HttpClientFactory.create('catalog')
    .withBulkheadIsolation(policy)
    .build();

// Live metrics via the handler
final handler = BulkheadIsolationHandler(policy);
print('active : ${handler.activeCount}');
print('queued : ${handler.queuedCount}');
print('free   : ${handler.semaphore.availableSlots}');
```

---

### Resilience policy engine (transport-agnostic)

`Policy` and `PolicyWrap` provide resilience logic that is independent
of HTTP — useful for wrapping any async operation (database calls,
file I/O, gRPC, etc.):

```dart
// Build via Policy factory
final policy = Policy.wrap([
  Policy.retry(maxRetries: 3),
  Policy.timeout(duration: Duration(seconds: 5)),
  Policy.bulkheadIsolation(maxConcurrentRequests: 10),
]);

final result = await policy.execute(() async {
  return await myService.fetchData();
});
```

Or use the fluent `ResiliencePipelineBuilder`:

```dart
final pipeline = ResiliencePipelineBuilder()
    .addPolicy(RetryResiliencePolicy(maxRetries: 3))
    .addPolicy(TimeoutResiliencePolicy(timeout: Duration(seconds: 5)))
    .build();

final result = await pipeline.execute(() => someOperation());
```

---

### Configuration-driven policies

Load policy parameters from JSON at runtime — useful for feature flags,
environment-specific tuning, and dynamic reconfiguration:

```dart
const json = '''
{
  "retry": { "maxRetries": 3, "baseDelayMs": 200 },
  "circuitBreaker": {
    "failureThreshold": 5,
    "breakDurationMs": 30000
  },
  "timeout": { "timeoutMs": 10000 }
}
''';

final config = ResilienceConfigLoader(JsonStringConfigSource(json));

final client = HttpClientFactory.create('remote')
    .withRetry(config.retryPolicy())
    .withCircuitBreaker(config.circuitBreakerPolicy(circuitName: 'remote'))
    .withTimeout(config.timeoutPolicy())
    .build();
```

---



* **Null-safe Dart 3** — strict null safety, strict casts, strict inference
* **Immutable models** — `HttpRequest` and `HttpResponse` are `final` value types
* **No reflection** — zero use of `dart:mirrors`; tree-shaker friendly
* **Async-first** — every pipeline operation is `Future`-based
* **SOLID** — single responsibility per handler, open/closed via composition,
  dependency inversion via abstractions
* **Clean Architecture** — dependency arrows point inward; `policies` ← `handlers` ← `factory`

---

## Running the example

```
cd example
dart run example.dart
```

## Running tests

```
dart test
```

---

## License

MIT — see [LICENSE](LICENSE).
