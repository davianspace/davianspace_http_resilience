# Architecture Overview

## Package Layout

```
davianspace_http_resilience/
├── lib/
│   ├── davianspace_http_resilience.dart    ← single library entry, all exports
│   └── src/
│       ├── core/               ← value types & primitives
│       │   ├── http_method.dart
│       │   ├── http_request.dart
│       │   ├── http_response.dart
│       │   ├── http_context.dart
│       │   └── cancellation_token.dart
│       │
│       ├── exceptions/         ← typed exception hierarchy
│       │   ├── http_resilience_exception.dart   (base)
│       │   ├── retry_exhausted_exception.dart
│       │   ├── circuit_open_exception.dart
│       │   ├── http_timeout_exception.dart
│       │   └── bulkhead_rejected_exception.dart
│       │
│       ├── pipeline/           ← handler abstractions & builder
│       │   ├── http_handler.dart             (abstract)
│       │   ├── delegating_handler.dart       (abstract, adds innerHandler)
│       │   ├── terminal_handler.dart         (concrete, does real I/O)
│       │   └── http_pipeline_builder.dart    (builder + NoOpPipeline)
│       │
│       ├── policies/           ← immutable policy configuration objects
│       │   ├── retry_policy.dart
│       │   ├── circuit_breaker_policy.dart   (+ CircuitBreakerState, Registry)
│       │   ├── timeout_policy.dart
│       │   └── bulkhead_policy.dart          (+ BulkheadSemaphore)
│       │
│       ├── handlers/           ← concrete DelegatingHandler implementations
│       │   ├── retry_handler.dart
│       │   ├── circuit_breaker_handler.dart
│       │   ├── timeout_handler.dart
│       │   ├── bulkhead_handler.dart
│       │   └── logging_handler.dart
│       │
│       ├── factory/            ← high-level client API
│       │   ├── resilient_http_client.dart    (verb helpers)
│       │   └── http_client_factory.dart      (builder + named registry)
│       │
│       └── utils/              ← extensions & helpers
│           ├── http_response_extensions.dart
│           └── retry_predicates.dart
│
├── test/
│   ├── core/
│   │   ├── http_request_test.dart
│   │   └── http_response_test.dart
│   ├── policies/
│   │   └── policies_test.dart
│   └── pipeline/
│       └── pipeline_test.dart
│
├── example/
│   └── example.dart
│
└── docs/
    └── architecture.md
```

---

## Dependency Graph

```
factory  ──────────────────────────────────────────────────────────────────►
  HttpClientFactory                                                  depends on
  ResilientHttpClient                                                │
                                                                     ▼
handlers ──────────────────────────────────────────────────────────────────►
  RetryHandler, CircuitBreakerHandler, TimeoutHandler,               depends on
  BulkheadHandler, LoggingHandler                                    │
                                                                     ▼
policies ──────────────────────────────────────────────────────────────────►
  RetryPolicy, CircuitBreakerPolicy, TimeoutPolicy,                  depends on
  BulkheadPolicy                                                     │
                                                                     ▼
pipeline ──────────────────────────────────────────────────────────────────►
  HttpHandler, DelegatingHandler, TerminalHandler,                   depends on
  HttpPipelineBuilder                                                │
                                                                     ▼
core     ──────────────────────────────────────────────────────────────────►
  HttpRequest, HttpResponse, HttpContext, CancellationToken          (no deps)
```

All arrows point **inward** — no layer has a compile-time dependency on any
layer above it.  `factory` knows about `handlers`; `handlers` know about
`policies`; `policies` know about `pipeline` types; `pipeline` knows only
about `core`.

---

## Pipeline execution sequence

```
   ┌─ LoggingHandler ─────────────────────────────────────────┐
   │  ┌─ RetryHandler ───────────────────────────────────────┐ │
   │  │  ┌─ CircuitBreakerHandler ──────────────────────────┐│ │
   │  │  │  ┌─ TimeoutHandler ───────────────────────────── ││ │
   │  │  │  │  ┌─ BulkheadHandler ─────────────────────────┐││ │
   │  │  │  │  │  TerminalHandler (http.Client.send())      │││ │
   │  │  │  │  └───────────────────────────────────────────┘││ │
   │  │  │  └───────────────────────────────────────────────┘│ │
   │  │  └────────────────────────────────────────────────────┘ │
   │  └──────────────────────────────────────────────────────── │
   └────────────────────────────────────────────────────────────┘

Request flows  ──────────────────────────────────────────────►
Response flows ◄────────────────────────────────────────────────
```

Each `DelegatingHandler.send()` call:
1. Executes **pre-processing** logic (check circuit, acquire semaphore, etc.)
2. Calls `await innerHandler.send(context)` to delegate down the chain
3. Executes **post-processing** logic (record success/failure, release semaphore, etc.)
4. Returns the `HttpResponse` upward

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
          │  (all requests rejected)       │          │  (one probe request allowed)   │
          └────────────────────────────────┘          └────────────────────────────────┘
                        │                                          ▲
                breakDuration elapsed                    any failure in half-open
                        │                                          │
                        └──────────────────────────────────────────┘
```
