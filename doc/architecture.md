# Architecture Overview

This document provides an in-depth technical overview of the
`davianspace_http_resilience` package architecture for engineers integrating
the library into production systems or contributing to the codebase.

---

## Table of Contents

- [Package Layout](#package-layout)
- [Dependency Graph](#dependency-graph)
- [Pipeline Execution Model](#pipeline-execution-model)
- [Handler Chain Sequence](#handler-chain-sequence)
- [Resilience Policies](#resilience-policies)
- [Circuit Breaker State Machine](#circuit-breaker-state-machine)
- [Configuration Layer](#configuration-layer)
- [Observability](#observability)
- [Resource Lifecycle](#resource-lifecycle)
- [Design Decisions](#design-decisions)

---

## Package Layout

```
davianspace_http_resilience/
├── lib/
│   ├── davianspace_http_resilience.dart    ← single barrel export
│   └── src/
│       ├── core/               ← value types & primitives
│       │   ├── http_method.dart
│       │   ├── http_request.dart         (+ streamingKey metadata constant)
│       │   ├── http_response.dart        (effectively immutable, streaming support)
│       │   ├── http_context.dart         (mutable per-request state bag)
│       │   ├── cancellation_token.dart   (memoised onCancelled future)
│       │   └── core.dart                 (barrel)
│       │
│       ├── exceptions/         ← typed exception hierarchy
│       │   ├── http_resilience_exception.dart   (base)
│       │   ├── http_status_exception.dart       (64 KB body cap)
│       │   ├── retry_exhausted_exception.dart
│       │   ├── circuit_open_exception.dart
│       │   ├── http_timeout_exception.dart
│       │   ├── bulkhead_rejected_exception.dart
│       │   ├── cancellation_exception.dart
│       │   └── exceptions.dart                  (barrel)
│       │
│       ├── pipeline/           ← handler abstractions & builder
│       │   ├── http_handler.dart             (abstract base)
│       │   ├── delegating_handler.dart       (middleware base, adds innerHandler)
│       │   ├── terminal_handler.dart         (HTTP I/O, per-request streaming)
│       │   ├── http_pipeline_builder.dart    (builder + NoOpPipeline)
│       │   ├── http_pipeline.dart
│       │   └── pipeline.dart                 (barrel)
│       │
│       ├── policies/           ← immutable policy configuration objects
│       │   ├── retry_policy.dart
│       │   ├── circuit_breaker_policy.dart   (+ CircuitBreakerState, Registry, health API)
│       │   ├── timeout_policy.dart
│       │   ├── bulkhead_policy.dart          (+ BulkheadSemaphore, Queue-based)
│       │   ├── hedging_policy.dart           (speculative execution config)
│       │   ├── fallback_policy.dart          (status/exception fallback config)
│       │   └── policies.dart                 (barrel)
│       │
│       ├── handlers/           ← concrete DelegatingHandler implementations
│       │   ├── retry_handler.dart
│       │   ├── circuit_breaker_handler.dart
│       │   ├── timeout_handler.dart
│       │   ├── bulkhead_handler.dart
│       │   ├── bulkhead_isolation_handler.dart
│       │   ├── hedging_handler.dart
│       │   ├── fallback_handler.dart
│       │   ├── logging_handler.dart          (header redaction, structured logging)
│       │   ├── policy_handler.dart           (bridge: ResiliencePolicy → pipeline)
│       │   └── handlers.dart                 (barrel)
│       │
│       ├── resilience/         ← transport-agnostic policy engine
│       │   ├── resilience_policy.dart        (abstract base + dispose())
│       │   ├── retry_resilience_policy.dart   (onRetry callback, isLastAttempt)
│       │   ├── circuit_breaker_resilience_policy.dart (Stopwatch-based timing)
│       │   ├── timeout_resilience_policy.dart
│       │   ├── bulkhead_resilience_policy.dart  (slot-leak-safe semaphore)
│       │   ├── bulkhead_isolation_resilience_policy.dart
│       │   ├── fallback_resilience_policy.dart
│       │   ├── backoff.dart                  (shared _defaultRandom)
│       │   ├── policy.dart                   (static factory)
│       │   ├── policy_wrap.dart              (composition + recursive dispose)
│       │   ├── resilience_pipeline_builder.dart
│       │   ├── policy_registry.dart          (named store, typed resolution)
│       │   ├── outcome_classifier.dart
│       │   └── resilience.dart               (barrel)
│       │
│       ├── factory/            ← high-level client API
│       │   ├── resilient_http_client.dart    (verb helpers, dispose lifecycle)
│       │   ├── http_client_factory.dart      (builder + named registry + disposal)
│       │   ├── fluent_http_client_builder.dart
│       │   └── factory.dart                  (barrel)
│       │
│       ├── config/             ← JSON configuration layer
│       │   ├── resilience_config.dart        (7 config sections incl. hedging/fallback)
│       │   ├── resilience_config_loader.dart (JSON parser)
│       │   ├── resilience_config_binder.dart (config → policy instances)
│       │   ├── resilience_config_source.dart
│       │   └── config.dart                   (barrel)
│       │
│       ├── observability/      ← event hub
│       │   ├── resilience_event_hub.dart
│       │   ├── resilience_event.dart
│       │   └── observability.dart            (barrel)
│       │
│       └── utils/              ← extensions & helpers
│           ├── http_response_extensions.dart
│           ├── retry_predicates.dart
│           └── utils.dart                    (barrel)
│
├── test/                        ← 926 tests across 25 files
│   ├── config/
│   ├── core/
│   ├── factory/
│   ├── handlers/
│   ├── observability/
│   ├── pipeline/
│   ├── policies/
│   └── resilience/
│
├── example/
│   └── example.dart
│
├── doc/
│   └── architecture.md          ← this file
│
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE                       (MIT)
├── README.md
├── pubspec.yaml
└── analysis_options.yaml         (strict-casts, strict-inference, strict-raw-types)
```

---

## Dependency Graph

```
 ┌─────────┐
 │ factory  │  HttpClientFactory, HttpClientBuilder, ResilientHttpClient
 └────┬─────┘
      │  depends on
      ▼
 ┌──────────┐
 │ handlers │  RetryHandler, CircuitBreakerHandler, TimeoutHandler,
 │          │  BulkheadHandler, BulkheadIsolationHandler, HedgingHandler,
 │          │  FallbackHandler, LoggingHandler, PolicyHandler
 └────┬─────┘
      │  depends on
      ▼
 ┌──────────┐
 │ policies │  RetryPolicy, CircuitBreakerPolicy, TimeoutPolicy,
 │          │  BulkheadPolicy, BulkheadIsolationPolicy, HedgingPolicy,
 │          │  FallbackPolicy
 └────┬─────┘
      │  depends on
      ▼
 ┌──────────┐
 │ pipeline │  HttpHandler, DelegatingHandler, TerminalHandler
 └────┬─────┘
      │  depends on
      ▼
 ┌──────────┐
 │   core   │  HttpRequest, HttpResponse, HttpContext, CancellationToken
 └──────────┘  (no internal dependencies)
```

**All arrows point inward.** No layer has a compile-time dependency on any
layer above it. `factory` knows about `handlers`; `handlers` know about
`policies`; `policies` know about `pipeline` types; `pipeline` knows only
about `core`.

**Cross-cutting concerns:**
- `config` depends on `policies` and `resilience` to bind config → policy instances.
- `observability` depends only on `core` — policies/handlers reference it optionally.
- `resilience` (policy engine) depends on `core` only — it is transport-agnostic.

---

## Pipeline Execution Model

### Request / Response Flow

```
   ┌─ LoggingHandler ─────────────────────────────────────────────────────┐
   │  ┌─ RetryHandler ───────────────────────────────────────────────────┐│
   │  │  ┌─ CircuitBreakerHandler ──────────────────────────────────────┐││
   │  │  │  ┌─ TimeoutHandler ─────────────────────────────────────────┐│││
   │  │  │  │  ┌─ BulkheadHandler / BulkheadIsolationHandler ─────────┐││││
   │  │  │  │  │  ┌─ HedgingHandler ─────────────────────────────────┐│││││
   │  │  │  │  │  │  ┌─ FallbackHandler ────────────────────────────┐││││││
   │  │  │  │  │  │  │  TerminalHandler (http.Client.send())        │││││││
   │  │  │  │  │  │  └──────────────────────────────────────────────┘││││││
   │  │  │  │  │  └──────────────────────────────────────────────────┘│││││
   │  │  │  │  └──────────────────────────────────────────────────────┘││││
   │  │  │  └──────────────────────────────────────────────────────────┘│││
   │  │  └──────────────────────────────────────────────────────────────┘││
   │  └──────────────────────────────────────────────────────────────────┘│
   └──────────────────────────────────────────────────────────────────────┘

   Request flows  ────────────────────────────────────────────────────────►
   Response flows ◄────────────────────────────────────────────────────────
```

### Handler Contract

Each handler implements:

```dart
Future<HttpResponse> send(HttpContext context);
```

`DelegatingHandler.send()` execution sequence:

1. **Pre-processing** — check circuit state, acquire semaphore, start timer
2. **Delegation** — `await innerHandler.send(context)`
3. **Post-processing** — record success/failure, release semaphore, log metrics
4. **Return** — `HttpResponse` propagates upward through the chain

### TerminalHandler — Per-Request Streaming

`TerminalHandler` checks the well-known metadata key
`HttpRequest.streamingKey` on each request. When present, it overrides the
handler-level `streamingMode` default:

```dart
final perRequest = context.request.metadata[HttpRequest.streamingKey] as bool?;
final streaming = perRequest ?? streamingMode;
```

This allows callers to opt individual requests into or out of streaming
without reconfiguring the pipeline.

---

## Handler Chain Sequence

### Recommended Production Order

| Position | Handler | Purpose |
|----------|---------|---------|
| 1 (outermost) | `LoggingHandler` | Logs full request/response round-trip with header redaction |
| 2 | `RetryHandler` | Retries transient failures within the time budget |
| 3 | `CircuitBreakerHandler` | Fast-fails when the downstream is unhealthy |
| 4 | `TimeoutHandler` | Per-attempt deadline enforcement |
| 5 | `BulkheadHandler` / `BulkheadIsolationHandler` | Concurrency control and back-pressure |
| 6 | `HedgingHandler` | Speculative requests for idempotent operations |
| 7 | `FallbackHandler` | Cached / synthetic response on downstream failure |
| 8 (innermost) | `TerminalHandler` | Real HTTP I/O via `package:http` |

> The order matters: logging wraps everything to capture the full lifecycle;
> retry is outside the circuit breaker so retries can trigger half-open probes;
> timeout bounds each individual attempt within a retry loop.

---

## Resilience Policies

### Transport-Agnostic Policy Engine

The `resilience/` layer provides policies independent of HTTP. They can wrap
any `Future<T>` operation — database calls, file I/O, gRPC, message queues:

```
                    ResiliencePolicy (abstract base)
                    ┌──────────────────────────────┐
                    │  Future<T> execute<T>(        │
                    │    Future<T> Function() action │
                    │  );                           │
                    │  void dispose();              │
                    └──────────┬───────────────────┘
                               │
    ┌──────────────┬──────────┼──────────┬──────────────┐
    ▼              ▼          ▼          ▼              ▼
 Retry     CircuitBreaker  Timeout  Bulkhead       Fallback
 Policy    Policy          Policy   Policy         Policy
                                       │
                                  Bulkhead
                                  Isolation
```

### PolicyWrap — Composition

`PolicyWrap` composes multiple policies into a single `ResiliencePolicy`:

```dart
final pipeline = Policy.wrap([
  Policy.timeout(duration: Duration(seconds: 10)),
  Policy.circuitBreaker(circuitName: 'svc'),
  Policy.retry(maxRetries: 3),
]);

final result = await pipeline.execute(() => myOperation());

// Recursive disposal
pipeline.dispose(); // disposes timeout + circuit breaker + retry
```

---

## Circuit Breaker State Machine

```
          ┌────────────────────────────────┐
          │           CLOSED               │
          │   (normal operation)           │◄──────────────────────┐
          └────────────────────────────────┘                       │
                        │                                          │
            consecutiveFailures >= failureThreshold                │
                        │                              successCount >= successThreshold
                        ▼                                          │
          ┌────────────────────────────────┐          ┌────────────────────────────────┐
          │            OPEN                │          │          HALF-OPEN             │
          │  (all requests rejected;       │          │  (one probe request allowed;   │
          │   throws CircuitOpenException) │          │   monitoring for recovery)     │
          └────────────────────────────────┘          └────────────────────────────────┘
                        │                                          ▲
                breakDuration elapsed                    any failure in half-open
                (Stopwatch-based, not wall-clock)                  │
                        └──────────────────────────────────────────┘
```

### Implementation Details

- **Timing**: `Stopwatch` is used for break-duration measurement, eliminating
  sensitivity to system clock skew or NTP adjustments.
- **Timestamps**: `_openedAt` and `_lastTransitionAt` use `DateTime.now().toUtc()`
  for consistent cross-timezone serialisation in diagnostics.
- **Registry**: `CircuitBreakerRegistry` provides `isHealthy()`, `snapshot()`,
  `contains()`, `circuitNames`, and `[]` operator for production monitoring
  and health-check endpoints.
- **Shared State**: Circuits with the same `circuitName` share state across
  all handler and policy instances — useful for multi-client architectures.

---

## Configuration Layer

### JSON Structure

```json
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
    "Bulkhead": {
      "MaxConcurrency": 20,
      "MaxQueueDepth": 100,
      "QueueTimeoutSeconds": 10
    },
    "BulkheadIsolation": {
      "MaxConcurrentRequests": 10,
      "MaxQueueSize": 100,
      "QueueTimeoutSeconds": 10
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
```

### Processing Pipeline

```
 JSON string
      │
      ▼
 ResilienceConfigLoader.load()     ← parses JSON, validates types
      │
      ▼
 ResilienceConfig                  ← immutable typed model (7 optional sections)
      │
      ▼
 ResilienceConfigBinder            ← builds concrete policy instances
      │
      ├──► buildPipeline(config)   → composed ResiliencePolicy
      ├──► buildRetry(config)      → RetryResiliencePolicy
      ├──► buildTimeout(config)    → TimeoutResiliencePolicy
      ├──► buildCircuitBreaker()   → CircuitBreakerResiliencePolicy
      ├──► buildBulkhead()         → BulkheadResiliencePolicy
      ├──► buildBulkheadIsolation()→ BulkheadIsolationResiliencePolicy
      ├──► buildHedging()          → HedgingPolicy
      └──► buildFallbackPolicy()   → FallbackPolicy (requires programmatic action)
```

### Design Rationale

- **Optional sections**: Missing JSON sections → `null` config field → policy
  not added to pipeline. Zero-config is valid.
- **Fallback separation**: `FallbackConfig` only captures trigger status codes.
  The actual fallback action (Dart code) must always be supplied
  programmatically — it cannot be serialised in JSON.
- **PascalCase keys**: JSON keys use PascalCase (`.NET appsettings.json`
  convention) for consistency with the upstream inspiration.

---

## Observability

### Event Hub

`ResilienceEventHub` provides a broadcast `Stream<ResilienceEvent>` for all
policy lifecycle events:

| Event Type | When Emitted |
|------------|--------------|
| `RetryEvent` | Each retry attempt (includes attempt number, exception) |
| `CircuitOpenEvent` | Circuit breaker transitions to Open |
| `CircuitCloseEvent` | Circuit breaker transitions to Closed |
| `TimeoutEvent` | Request exceeds timeout deadline |
| `FallbackEvent` | Fallback action triggers |
| `BulkheadRejectedEvent` | Request rejected (queue full or queue timeout) |

Events are dispatched via `scheduleMicrotask` to prevent listener exceptions
from disrupting the pipeline.

### Circuit Breaker Health API

```dart
final registry = CircuitBreakerRegistry.instance;

// Single circuit
registry.isHealthy('payments');   // true if Closed
registry.snapshot('payments');     // CircuitBreakerSnapshot (state, counters, timestamps)

// All circuits
registry.circuitNames;            // Iterable<String>
registry.contains('payments');    // bool
registry['payments'];             // CircuitBreakerState (operator [])
```

---

## Resource Lifecycle

### Disposal Hierarchy

```
ResilientHttpClient.dispose()
      │
      ├── onDispose callback (from HttpClientBuilder)
      │       │
      │       └── Disposes each PolicyHandler's ResiliencePolicy
      │               ├── RetryResiliencePolicy.dispose()
      │               ├── CircuitBreakerResiliencePolicy.dispose()
      │               ├── TimeoutResiliencePolicy.dispose()
      │               ├── BulkheadResiliencePolicy.dispose()
      │               └── PolicyWrap.dispose() (recursive)
      │
      └── TerminalHandler.dispose()
              │
              └── Closes internally-owned http.Client
                  (injected clients are NOT closed)
```

### Ownership Rules

| Resource | Created By | Disposed By |
|----------|-----------|-------------|
| `http.Client` (internal) | `TerminalHandler` | `TerminalHandler.dispose()` |
| `http.Client` (injected) | Caller | Caller's responsibility |
| `ResiliencePolicy` instances | `ResilienceConfigBinder` / `Policy` factory | `PolicyWrap.dispose()` or manual |
| `ResilientHttpClient` | `HttpClientBuilder.build()` | `ResilientHttpClient.dispose()` |

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **No reflection** | Zero use of `dart:mirrors`; tree-shaker friendly; compatible with AOT compilation |
| **`final class` everywhere** | Prevents inheritance outside the package; enables sealed-class optimisations |
| **Immutable value types** | `HttpRequest` and `HttpResponse` are `@immutable final class` — safe for caching, logging, and concurrent access |
| **Stopwatch for circuit timing** | Immune to system clock adjustments (NTP, DST); monotonic elapsed time |
| **`Queue` for bulkhead** | O(1) `removeFirst()` vs O(n) `removeAt(0)` on `List` — matters under high contention |
| **Memoised `CancellationToken.onCancelled`** | Repeated listeners share the same `Future<void>`; prevents allocations in hot paths |
| **Shared `Random` instance** | Single `_defaultRandom` across all backoff strategies avoids per-call allocation and improves jitter distribution |
| **64 KB body cap on exceptions** | Prevents unbounded memory consumption when logging error responses |
| **PascalCase JSON keys** | Follows .NET `appsettings.json` convention for familiarity in hybrid Dart/.NET shops |
| **Header redaction by default** | `LoggingHandler` redacts `authorization`, `cookie`, `set-cookie`, `proxy-authorization`, `x-api-key` to prevent credential leakage in log sinks |
