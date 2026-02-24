# davianspace_http_resilience

[![pub version](https://img.shields.io/pub/v/davianspace_http_resilience.svg)](https://pub.dev/packages/davianspace_http_resilience)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue.svg)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Tests](https://img.shields.io/badge/tests-926%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/analyzer-0%20issues-brightgreen)

A **production-grade** Dart / Flutter HTTP resilience library inspired by
[Microsoft.Extensions.Http.Resilience](https://learn.microsoft.com/en-us/dotnet/core/resilience/http-resilience)
and [Polly](https://github.com/App-vNext/Polly).

Built for **enterprise workloads**: composable middleware pipelines, seven
resilience policies, structured observability, configuration-driven setup,
deterministic resource lifecycle, and header-redacted security logging — all
with zero reflection and strict null-safety.

---

## Table of Contents

- [Why This Package?](#why-this-package)
- [Features at a Glance](#features-at-a-glance)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Usage Guide](#usage-guide)
  - [Retry Policy](#retry-policy)
  - [Circuit Breaker](#circuit-breaker)
  - [Timeout Policy](#timeout-policy)
  - [Bulkhead (Concurrency Control)](#bulkhead-concurrency-control)
  - [Bulkhead Isolation](#bulkhead-isolation)
  - [Hedging (Speculative Execution)](#hedging-speculative-execution)
  - [Fallback](#fallback)
  - [Per-Request Streaming](#per-request-streaming)
  - [Custom Handlers](#custom-handlers)
  - [Named Client Factory](#named-client-factory)
  - [Cancellation](#cancellation)
  - [Response Helpers](#response-helpers)
  - [Transport-Agnostic Policy Engine](#transport-agnostic-policy-engine)
  - [Configuration-Driven Policies](#configuration-driven-policies)
  - [Observability & Events](#observability--events)
  - [Health Checks & Monitoring](#health-checks--monitoring)
  - [Header Redaction (Security Logging)](#header-redaction-security-logging)
- [Lifecycle & Disposal](#lifecycle--disposal)
- [Testing](#testing)
- [API Reference](#api-reference)
- [Migration Guide](#migration-guide)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## Why This Package?

| Concern | How We Address It |
|---------|-------------------|
| **Transient failures** | Retry with constant, linear, exponential, and jittered back-off |
| **Cascading failures** | Circuit breaker with Closed → Open → Half-Open state machine |
| **Tail latency** | Hedging fires speculative requests after a configurable delay |
| **Degraded service** | Fallback returns a cached / synthetic response on failure |
| **Slow endpoints** | Per-attempt and total-operation timeout deadlines |
| **Overload protection** | Bulkhead + bulkhead-isolation with queue-depth limits |
| **Security** | Automatic header redaction in logs (auth, cookies, API keys) |
| **Ops visibility** | Event hub, circuit health checks, live semaphore metrics |
| **Config flexibility** | JSON-driven policy configuration with runtime reload |
| **Resource safety** | `dispose()` on every policy, handler, and client |

---

## Features at a Glance

| Feature | Description |
|---------|-------------|
| **Composable middleware pipeline** | Chain any number of handlers in a type-safe, ordered pipeline |
| **Retry policy** | Constant, linear, exponential, and decorrelated-jitter back-off with composable predicates |
| **Circuit breaker** | Closed / Open / Half-Open state machine with shared circuit registries |
| **Timeout policy** | Per-attempt or total-operation deadlines |
| **Bulkhead (concurrency limiter)** | Bounded max-parallel + queue-depth with back-pressure |
| **Bulkhead isolation** | Semaphore-based isolation with completer-signalling and live metrics |
| **Hedging** | Speculative execution to reduce tail latency for idempotent operations |
| **Fallback** | Status-code or exception predicate with async fallback action |
| **Per-request streaming** | Override the pipeline streaming mode per-request via metadata |
| **Configuration-driven policies** | `ResilienceConfigLoader` + JSON sources bind policies at runtime |
| **Fluent builder DSL** | `FluentHttpClientBuilder` for expressive, step-by-step client construction |
| **Structured logging** | Header-redacted structured logging via `package:logging` |
| **Typed HTTP client** | Ergonomic `get` / `post` / `put` / `patch` / `delete` / `head` / `options` verbs |
| **Named client registry** | `HttpClientFactory` for shared, lifecycle-managed clients |
| **Cancellation support** | `CancellationToken` for cooperative cancellation across the pipeline |
| **Response extensions** | `ensureSuccess()`, `bodyAsString`, `bodyAsJsonMap`, `bodyAsJsonList` |
| **Retry predicate DSL** | Composable `RetryPredicates` with `.or()` / `.and()` combinators |
| **Transport-agnostic policy engine** | `Policy.wrap` for any async operation (DB, gRPC, file I/O) |
| **Event hub** | `ResilienceEventHub` broadcasts retry, circuit, timeout, fallback, and bulkhead events |
| **Health checks** | `CircuitBreakerRegistry` snapshots for readiness/liveness probes |
| **Deterministic disposal** | `dispose()` on policies, handlers, and clients for leak-free operation |

---

## Requirements

| Requirement | Version |
|-------------|---------|
| Dart SDK | `>=3.0.0 <4.0.0` |
| Flutter | Any (optional — works as pure Dart) |

**Runtime dependencies** (all from pub.dev):

| Package | Version |
|---------|---------|
| `http` | `^1.2.1` |
| `logging` | `^1.2.0` |
| `meta` | `^1.12.0` |

---

## Installation

```yaml
dependencies:
  davianspace_http_resilience: ^1.0.1
```

```bash
dart pub get
```

---

## Quick Start

### Option A — Fluent factory (recommended for production)

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

  try {
    final body = await client
        .get(Uri.parse('/users/42'))
        .then((r) => r.ensureSuccess().bodyAsJsonMap);
    print(body);
  } finally {
    client.dispose(); // Always dispose when done
  }
}
```

### Option B — Lightweight builder (tests, scripts, one-off clients)

```dart
final client = HttpClientBuilder('catalog')
    .withRetry(RetryPolicy.constant(maxRetries: 2))
    .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 5)))
    .build();

try {
  final response = await client.get(Uri.parse('https://api.example.com/items'));
  print(response.bodyAsString);
} finally {
  client.dispose();
}
```

### Option C — Configuration-driven (enterprise / multi-environment)

```dart
const configJson = '''
{
  "Resilience": {
    "Retry": { "MaxRetries": 3, "Backoff": { "Type": "exponential", "BaseMs": 200, "UseJitter": true } },
    "Timeout": { "Seconds": 10 },
    "CircuitBreaker": { "CircuitName": "api", "FailureThreshold": 5, "BreakSeconds": 30 },
    "BulkheadIsolation": { "MaxConcurrentRequests": 20, "MaxQueueSize": 50 },
    "Hedging": { "HedgeAfterMs": 300, "MaxHedgedAttempts": 2 },
    "Fallback": { "StatusCodes": [500, 502, 503, 504] }
  }
}
''';

const loader = ResilienceConfigLoader();
const binder = ResilienceConfigBinder();

final config = loader.load(configJson);
final pipeline = binder.buildPipeline(config);

final result = await pipeline.execute(() => httpClient.get(uri));
```

---

## Architecture

```
Application code
      │
      ├── ResilienceConfigLoader  ← bind policies from JSON / env at runtime
      │         │
      │    JsonStringConfigSource / InMemoryConfigSource / custom source
      │
      ▼
HttpClientFactory  (named registry)   HttpClientBuilder  (lightweight)
      │                                       │
      └───────────────┬───────────────────────┘
                      ▼
            ResilientHttpClient    ← get / post / put / patch / delete / head / options
                      │
                      ▼
           HttpHandler pipeline    ← ordered chain of DelegatingHandler instances
     ┌─────────────────────────────────────────────────────────┐
     │  LoggingHandler              (outermost — logs, redacts)│
     │  RetryHandler                                           │
     │  CircuitBreakerHandler                                  │
     │  TimeoutHandler                                         │
     │  BulkheadHandler / BulkheadIsolationHandler             │
     │  HedgingHandler              (speculative execution)    │
     │  FallbackHandler             (status/exception fallback)│
     │  TerminalHandler             (innermost — HTTP I/O)     │
     └─────────────────────────────────────────────────────────┘
                      │
                      ▼
              package:http  (http.Client)
```

### Pipeline Execution Order

Each handler implements:

```dart
Future<HttpResponse> send(HttpContext context);
```

Handlers are linked via `DelegatingHandler.innerHandler`. The outermost
handler executes first; `TerminalHandler` performs the actual network I/O.

### Dependency Direction — Clean Architecture

```
factory   →   handlers   →   policies   →   pipeline   →   core
```

All arrows point **inward**. No layer has a compile-time dependency on any
layer above it.

> For a detailed architecture breakdown including state-machine diagrams,
> dependency graphs, and sequence flows, see [`doc/architecture.md`](doc/architecture.md).

---

## Usage Guide

### Retry Policy

```dart
// Exponential back-off with full jitter, retrying only on 5xx + network errors
final policy = RetryPolicy.exponential(
  maxRetries: 4,
  baseDelay: Duration(milliseconds: 200),
  maxDelay: Duration(seconds: 30),
  useJitter: true,
  shouldRetry: RetryPredicates.serverErrors.or(RetryPredicates.networkErrors),
);

// With onRetry callback for telemetry
final retryPolicy = RetryResiliencePolicy(
  maxRetries: 3,
  backoff: ExponentialBackoff(
    Duration(milliseconds: 200),
    maxDelay: Duration(seconds: 30),
    useJitter: true,
  ),
  onRetry: (attempt, exception) {
    metrics.increment('http.retry', tags: {'attempt': '$attempt'});
  },
);
```

### Circuit Breaker

```dart
final policy = CircuitBreakerPolicy(
  circuitName: 'payments',   // shared across all clients with this name
  failureThreshold: 5,       // 5 consecutive failures trips the breaker
  successThreshold: 2,       // 2 successes in half-open state to close
  breakDuration: Duration(seconds: 30),
);
```

### Timeout Policy

```dart
// 10-second per-attempt deadline
final policy = TimeoutPolicy(timeout: Duration(seconds: 10));
```

### Bulkhead (Concurrency Control)

```dart
final policy = BulkheadPolicy(
  maxConcurrency: 20,
  maxQueueDepth: 100,
  queueTimeout: Duration(seconds: 10),
);
```

### Bulkhead Isolation

Semaphore-based isolation with rejection callbacks and live metrics:

```dart
final policy = BulkheadIsolationPolicy(
  maxConcurrentRequests: 10,
  maxQueueSize: 20,
  queueTimeout: Duration(seconds: 5),
  onRejected: (reason) =>
      log.warning('Bulkhead rejected: $reason'),  // queueFull or queueTimeout
);

final client = HttpClientFactory.create('catalog')
    .withBulkheadIsolation(policy)
    .build();

// Live metrics via the handler
final handler = BulkheadIsolationHandler(policy);
print('active: ${handler.activeCount}');
print('queued: ${handler.queuedCount}');
print('free:   ${handler.semaphore.availableSlots}');
```

### Hedging (Speculative Execution)

Hedging fires concurrent speculative requests to reduce tail latency.
**Use only for idempotent operations** (GET, HEAD, etc.).

```dart
final hedging = HedgingPolicy(
  hedgeAfter: Duration(milliseconds: 300),
  maxHedgedAttempts: 2,
);

final client = HttpClientBuilder('search')
    .withHedging(hedging)
    .build();
```

Or configure via JSON:

```json
{
  "Hedging": { "HedgeAfterMs": 300, "MaxHedgedAttempts": 2 }
}
```

### Fallback

Returns a cached or synthetic response when the downstream call fails:

```dart
final fallback = FallbackPolicy(
  fallbackAction: (context, error, stackTrace) async =>
      HttpResponse(statusCode: 200, body: utf8.encode('{"cached": true}')),
  shouldHandle: (response, exception, context) {
    if (exception != null) return true;
    return response != null && [500, 502, 503].contains(response.statusCode);
  },
);

final client = HttpClientBuilder('catalog')
    .withFallback(fallback)
    .build();
```

Or configure the trigger status codes via JSON, supplying only the action
programmatically:

```json
{
  "Fallback": { "StatusCodes": [500, 502, 503, 504] }
}
```

```dart
final policy = binder.buildFallbackPolicy(
  config.fallback!,
  fallbackAction: (ctx, err, st) async =>
      HttpResponse(statusCode: 200, body: utf8.encode('{"offline": true}')),
);
```

### Per-Request Streaming

Override the pipeline's default streaming mode on a per-request basis:

```dart
// Stream only this request (no body buffering):
final response = await client.get(
  Uri.parse('/large-file'),
  metadata: {HttpRequest.streamingKey: true},
);

// Force-buffer even when the pipeline default is streaming:
final response = await client.get(
  Uri.parse('/small-resource'),
  metadata: {HttpRequest.streamingKey: false},
);
```

### Custom Handlers

Extend `DelegatingHandler` to inject cross-cutting concerns:

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

final client = HttpClientBuilder('api')
    .addHandler(AuthHandler(() => tokenService.getAccessToken()))
    .withRetry(RetryPolicy.exponential(maxRetries: 3))
    .build();
```

### Named Client Factory

Register once, resolve anywhere:

```dart
// Register in main() or DI container
final factory = HttpClientFactory();

factory.addClient(
  'catalog',
  (b) => b
      .withBaseUri(Uri.parse('https://catalog.internal/v1'))
      .withRetry(RetryPolicy.exponential(maxRetries: 3))
      .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'catalog'))
      .withLogging(),
);

// Resolve anywhere in the application
final client = factory.createClient('catalog');
```

### Cancellation

```dart
final token = CancellationToken();

// Cancel from UI or lifecycle event
onDispose: () => token.cancel('widget disposed');

// Pass to the request context
final context = HttpContext(
  request: HttpRequest(method: HttpMethod.get, uri: uri),
  cancellationToken: token,
);
final response = await pipeline.send(context);
```

### Response Helpers

```dart
final response = await client.post(
  Uri.parse('/orders'),
  body: jsonEncode(order),
  headers: {'Content-Type': 'application/json'},
);

// Throws HttpStatusException for non-2xx
final map  = response.ensureSuccess().bodyAsJsonMap;
final list = response.ensureSuccess().bodyAsJsonList;
final text = response.bodyAsString;
```

### Transport-Agnostic Policy Engine

`Policy` and `PolicyWrap` provide resilience logic independent of HTTP —
wrap any async operation (database calls, file I/O, gRPC, etc.):

```dart
// Build via the Policy factory
final policy = Policy.wrap([
  Policy.retry(maxRetries: 3),
  Policy.timeout(duration: Duration(seconds: 5)),
  Policy.bulkheadIsolation(maxConcurrentRequests: 10),
]);

final result = await policy.execute(() async {
  return await myService.fetchData();
});

// Or use the fluent builder
final pipeline = ResiliencePipelineBuilder()
    .addPolicy(RetryResiliencePolicy(maxRetries: 3))
    .addPolicy(TimeoutResiliencePolicy(timeout: Duration(seconds: 5)))
    .build();

final result = await pipeline.execute(() => someOperation());
```

### Configuration-Driven Policies

Load all policy parameters from JSON — ideal for feature flags,
environment-specific tuning, and dynamic reconfiguration:

```dart
const json = '''
{
  "Resilience": {
    "Retry": {
      "MaxRetries": 3,
      "RetryForever": false,
      "Backoff": {
        "Type": "exponential",
        "BaseMs": 200,
        "MaxDelayMs": 30000,
        "UseJitter": true
      }
    },
    "Timeout": { "Seconds": 10 },
    "CircuitBreaker": {
      "CircuitName": "api",
      "FailureThreshold": 5,
      "SuccessThreshold": 1,
      "BreakSeconds": 30
    },
    "Bulkhead": { "MaxConcurrency": 20, "MaxQueueDepth": 100 },
    "BulkheadIsolation": { "MaxConcurrentRequests": 10, "MaxQueueSize": 50 },
    "Hedging": { "HedgeAfterMs": 300, "MaxHedgedAttempts": 2 },
    "Fallback": { "StatusCodes": [500, 502, 503, 504] }
  }
}
''';

const loader = ResilienceConfigLoader();
const binder = ResilienceConfigBinder();

final config = loader.load(json);

// Build a composed pipeline from all configured sections
final pipeline = binder.buildPipeline(config);

// Or build individual policies
final retry   = binder.buildRetry(config.retry!);
final timeout = binder.buildTimeout(config.timeout!);
final hedging = binder.buildHedging(config.hedging!);
final fallback = binder.buildFallbackPolicy(
  config.fallback!,
  fallbackAction: (ctx, err, st) async => HttpResponse(statusCode: 200),
);

// Register all policies into a named registry in one call
PolicyRegistry.instance.loadFromConfig(config);
```

### Observability & Events

```dart
final hub = ResilienceEventHub();

hub.stream.listen((event) {
  switch (event) {
    case RetryEvent():
      metrics.increment('resilience.retry', tags: {'attempt': '${event.attempt}'});
    case CircuitOpenEvent():
      alerting.fire('circuit-open', circuit: event.circuitName);
    case TimeoutEvent():
      metrics.increment('resilience.timeout');
    case FallbackEvent():
      metrics.increment('resilience.fallback');
    case BulkheadRejectedEvent():
      metrics.increment('resilience.bulkhead_rejected');
    default:
      break;
  }
});
```

### Health Checks & Monitoring

Use `CircuitBreakerRegistry` for readiness/liveness probes:

```dart
// Check circuit health
final registry = CircuitBreakerRegistry.instance;
final isHealthy = registry.isHealthy('payments');
final snapshot  = registry.snapshot('payments');

// List all registered circuits
final names = registry.circuitNames;

// Expose in a health endpoint
app.get('/health', (req, res) {
  final circuits = {
    for (final name in registry.circuitNames)
      name: registry.isHealthy(name),
  };
  final healthy = circuits.values.every((v) => v);
  res.statusCode = healthy ? 200 : 503;
  res.json({'status': healthy ? 'healthy' : 'degraded', 'circuits': circuits});
});
```

### Header Redaction (Security Logging)

`LoggingHandler` automatically redacts sensitive headers in log output:

```dart
final client = HttpClientBuilder('secure-api')
    .withLogging(LoggingHandler(
      logHeaders: true,
      // Default redacted set: authorization, proxy-authorization,
      // cookie, set-cookie, x-api-key
      redactedHeaders: {
        'authorization',
        'x-api-key',
        'x-custom-secret',  // Add your own
      },
    ))
    .withRetry(RetryPolicy.exponential(maxRetries: 3))
    .build();
```

---

## Lifecycle & Disposal

All stateful resources implement `dispose()` for deterministic cleanup:

```dart
// Client disposal (disposes pipeline + underlying http.Client)
final client = HttpClientBuilder('api').build();
try {
  await client.get(uri);
} finally {
  client.dispose();
}

// Policy disposal (disposes circuit-breaker state, semaphores, etc.)
final policy = Policy.wrap([
  Policy.retry(maxRetries: 3),
  Policy.circuitBreaker(circuitName: 'svc'),
]);
try {
  await policy.execute(() => fetchData());
} finally {
  policy.dispose();
}

// Factory disposal
final factory = HttpClientFactory();
factory.addClient('svc', (b) => b.withRetry(RetryPolicy.constant(maxRetries: 2)));
// ... later
factory.clear(); // disposes all registered clients
```

---

## Testing

```bash
# Run the full test suite (926 tests)
dart test

# Run with coverage
dart test --coverage=coverage

# Static analysis (zero issues required)
dart analyze --fatal-infos
```

The test suite covers:

| Area | Files | What's Tested |
|------|-------|---------------|
| **Core** | 3 | Request/response immutability, streaming, copy-with |
| **Config** | 1 | JSON parsing, all seven section parsers, edge cases |
| **Factory** | 3 | Fluent builder, named factory registry, verb helpers |
| **Handlers** | 2 | Hedging handler, structured logging + redaction |
| **Observability** | 2 | Event hub, error events, event types |
| **Pipeline** | 3 | Handler chaining, integration, pipeline builder |
| **Policies** | 3 | Circuit breaker sliding window, retry features, all policy configs |
| **Resilience** | 8 | Advanced retry, bulkhead isolation, concurrency stress, fallback, outcome classification, policy registry, namespaces |

---

## API Reference

### Core Types

| Type | Role |
|------|------|
| `HttpRequest` | Immutable outgoing request model with metadata bag |
| `HttpResponse` | Immutable response model with streaming support |
| `HttpContext` | Mutable per-request execution context (flows through pipeline) |
| `CancellationToken` | Cooperative cancellation with memoised `onCancelled` future |

### Pipeline

| Type | Role |
|------|------|
| `HttpHandler` | Abstract pipeline handler |
| `DelegatingHandler` | Middleware base with `innerHandler` chaining |
| `TerminalHandler` | Innermost handler — performs HTTP I/O |

### Policies (Handler-Level Configuration)

| Type | Role |
|------|------|
| `RetryPolicy` | Retry strategy: constant / linear / exponential back-off |
| `CircuitBreakerPolicy` | Threshold + break-duration circuit control |
| `TimeoutPolicy` | Per-attempt deadline |
| `BulkheadPolicy` | Max concurrency + queue depth |
| `BulkheadIsolationPolicy` | Semaphore-based isolation with rejection callbacks |
| `HedgingPolicy` | Speculative execution for tail-latency reduction |
| `FallbackPolicy` | Fallback action triggered by status code or exception |

### Resilience Engine (Transport-Agnostic)

| Type | Role |
|------|------|
| `ResiliencePolicy` | Abstract composable policy base with `dispose()` |
| `RetryResiliencePolicy` | Free-standing retry with back-off and `onRetry` callback |
| `CircuitBreakerResiliencePolicy` | Free-standing circuit breaker |
| `TimeoutResiliencePolicy` | Free-standing timeout |
| `BulkheadResiliencePolicy` | Free-standing concurrency limiter |
| `BulkheadIsolationResiliencePolicy` | Free-standing isolation with zero-polling semaphore |
| `FallbackResiliencePolicy` | Free-standing fallback |
| `Policy` | Static factory for all resilience policies |
| `PolicyWrap` | Composable multi-policy pipeline with introspection and `dispose()` |
| `ResiliencePipelineBuilder` | Fluent builder for `PolicyWrap` |
| `PolicyRegistry` | Named policy store with typed resolution |

### Configuration

| Type | Role |
|------|------|
| `ResilienceConfig` | Immutable top-level config (7 optional sections) |
| `ResilienceConfigLoader` | Parses JSON → `ResilienceConfig` |
| `ResilienceConfigBinder` | Binds config → policy instances |
| `ResilienceConfigSource` | Abstraction for static/dynamic config sources |
| `JsonStringConfigSource` | Static config source backed by a JSON string |
| `InMemoryConfigSource` | Dynamic config source with live-update support |

### Observability

| Type | Role |
|------|------|
| `ResilienceEventHub` | Centralized event bus (scheduleMicrotask dispatch) |
| `ResilienceEvent` | Sealed base class for all lifecycle events |
| `CircuitBreakerRegistry` | Circuit health checks, snapshot, and enumeration |

### Client Factory

| Type | Role |
|------|------|
| `HttpClientFactory` | Named + typed client factory with lifecycle management |
| `HttpClientBuilder` | Fluent pipeline builder for `ResilientHttpClient` |
| `FluentHttpClientBuilder` | Immutable fluent DSL |
| `ResilientHttpClient` | High-level HTTP client with verb helpers |

---

## Migration Guide

### From 1.0.0 → 1.0.1

**No breaking changes.** Version 1.0.1 is fully backward-compatible.

New features available after upgrading:

1. **`ResiliencePolicy.dispose()`** — Call `dispose()` on policies when done.
   Existing code that does not call `dispose()` will continue to work but may
   leak resources in long-running processes.

2. **Hedging/Fallback config** — `ResilienceConfigLoader` now recognises
   `"Hedging"` and `"Fallback"` JSON sections. Existing configs without these
   sections are unaffected.

3. **Per-request streaming** — Set `metadata: {HttpRequest.streamingKey: true}`
   on any verb call. The default behaviour (handler-level `streamingMode`)
   is unchanged when the key is absent.

4. **Header redaction** — `LoggingHandler` now accepts `redactedHeaders` and
   `logHeaders`. Existing `LoggingHandler()` calls use the default redaction
   set automatically.

5. **`onRetry` callback** — `RetryResiliencePolicy` accepts an optional
   `onRetry` callback. Existing code without it is unaffected.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding
standards, and pull-request guidelines.

---

## Security

For security concerns and responsible disclosure, see [SECURITY.md](SECURITY.md).

---

## License

MIT — see [LICENSE](LICENSE).
