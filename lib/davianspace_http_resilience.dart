/// # davianspace_http_resilience
///
/// A production-grade Dart / Flutter HTTP resilience library inspired by
/// [Microsoft.Extensions.Http.Resilience](https://learn.microsoft.com/en-us/dotnet/core/resilience/http-resilience)
/// and [Polly](https://github.com/App-vNext/Polly).
///
/// Built for **enterprise workloads**: composable middleware pipelines, seven
/// resilience policies, structured observability, configuration-driven setup,
/// deterministic resource lifecycle, and header-redacted security logging —
/// all with zero reflection and strict null-safety.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
///
/// void main() async {
///   final client = HttpClientFactory.create('demo')
///       .withBaseUri(Uri.parse('https://api.example.com'))
///       .withDefaultHeader('Accept', 'application/json')
///       .withLogging()
///       .withRetry(RetryPolicy.exponential(maxRetries: 3, useJitter: true))
///       .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'demo'))
///       .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10)))
///       .build();
///
///   try {
///     final response = await client.get(Uri.parse('/todos/1'));
///     print(response.ensureSuccess().bodyAsString);
///   } finally {
///     client.dispose();
///   }
/// }
/// ```
///
/// ## Architecture
///
/// ```
/// Application code
///       │
///       ├── ResilienceConfigLoader  ← bind policies from JSON at runtime
///       │
///       ▼
/// ResilientHttpClient              ← get / post / put / patch / delete / head / options
///       │
///       ▼
/// HttpHandler pipeline             ← ordered chain of DelegatingHandler instances
///   ┌───────────────────────────┐
///   │ LoggingHandler            │  1. outermost — logs round-trip, redacts headers
///   │ RetryHandler              │  2. retries transient failures
///   │ CircuitBreakerHandler     │  3. fast-fail when threshold exceeded
///   │ TimeoutHandler            │  4. per-attempt deadline
///   │ BulkheadHandler           │  5. limits concurrency
///   │ HedgingHandler            │  6. speculative execution (tail latency)
///   │ FallbackHandler           │  7. cached / synthetic fallback on failure
///   │ TerminalHandler           │  8. innermost — real HTTP I/O (package:http)
///   └───────────────────────────┘
/// ```
///
/// ## Key Types
///
/// ### Core
///
/// | Type                      | Role |
/// |---------------------------|------|
/// | [`HttpRequest`]           | Immutable outgoing request model with metadata bag |
/// | [`HttpResponse`]          | Immutable response model with streaming support |
/// | [`HttpContext`]           | Mutable per-request execution context |
/// | [`CancellationToken`]     | Cooperative cancellation with memoised future |
///
/// ### Pipeline
///
/// | Type                      | Role |
/// |---------------------------|------|
/// | [`HttpHandler`]           | Abstract pipeline handler |
/// | [`DelegatingHandler`]     | Middleware base with inner-handler chaining |
///
/// ### Policy Configuration (Handler-Level)
///
/// | Type                      | Role |
/// |---------------------------|------|
/// | [`RetryPolicy`]           | Constant / linear / exponential back-off |
/// | [`CircuitBreakerPolicy`]  | Failure-threshold circuit control |
/// | [`TimeoutPolicy`]         | Per-attempt timeout |
/// | [`BulkheadPolicy`]        | Max-concurrency + queue isolation |
/// | [`BulkheadIsolationPolicy`] | Semaphore-based isolation with rejection callbacks |
/// | [`HedgingPolicy`]         | Speculative execution for idempotent operations |
/// | [`FallbackPolicy`]        | Fallback action on status code / exception |
///
/// ### Resilience Engine (Transport-Agnostic)
///
/// | Type                      | Role |
/// |---------------------------|------|
/// | [`ResiliencePolicy`]      | Abstract composable policy base with `dispose()` |
/// | [`PolicyHandler`]         | Bridge: applies [`ResiliencePolicy`] inside a pipeline |
/// | [`Policy`]                | Static factory for all resilience policies |
/// | [`PolicyWrap`]            | Ordered multi-policy pipeline with introspection |
/// | [`ResiliencePipelineBuilder`] | Fluent builder for composing policies |
/// | [`PolicyRegistry`]        | Named policy store with typed resolution |
///
/// ### Client Factory
///
/// | Type                      | Role |
/// |---------------------------|------|
/// | [`HttpClientFactory`]     | Named + typed client factory with lifecycle management |
/// | [`HttpClientBuilder`]     | Fluent pipeline builder for [`ResilientHttpClient`] |
/// | [`ResilientHttpClient`]   | High-level HTTP client with verb helpers |
/// | [`FluentHttpClientBuilder`] | Immutable fluent DSL for step-by-step construction |
///
/// ### Configuration
///
/// | Type                      | Role |
/// |---------------------------|------|
/// | [`ResilienceConfig`]      | Immutable config model (7 policy sections) |
/// | [`ResilienceConfigLoader`]| Parses JSON → [`ResilienceConfig`] |
/// | [`ResilienceConfigBinder`]| Binds config → policy instances |
/// | [`JsonStringConfigSource`]| Static config source backed by a JSON string |
/// | [`InMemoryConfigSource`]  | Dynamic config source with live-update support |
///
/// ### Observability
///
/// | Type                        | Role |
/// |-----------------------------|------|
/// | [`ResilienceEventHub`]      | Centralized event bus for policy lifecycle events |
/// | [`ResilienceEvent`]         | Sealed base class for all resilience events |
/// | [`RetryEvent`]              | Emitted on each retry attempt |
/// | [`CircuitOpenEvent`]        | Emitted when circuit breaker opens |
/// | [`CircuitCloseEvent`]       | Emitted when circuit breaker closes |
/// | [`TimeoutEvent`]            | Emitted when a timeout occurs |
/// | [`FallbackEvent`]           | Emitted when a fallback triggers |
/// | [`BulkheadRejectedEvent`]   | Emitted when bulkhead rejects a request |
///
/// ### Classification & Exceptions
///
/// | Type                        | Role |
/// |-----------------------------|------|
/// | [`OutcomeClassifier`]       | Classifies HTTP outcomes as success / transient / permanent |
/// | [`HttpOutcomeClassifier`]   | Default HTTP outcome classifier (2xx/4xx/5xx) |
/// | [`OutcomeClassification`]   | Enum: success, transientFailure, permanentFailure |
/// | [`HttpResilienceException`] | Base exception for all resilience failures |
/// | [`HttpStatusException`]     | Non-2xx HTTP response (body capped at 64 KB) |
/// | [`RetryExhaustedException`] | All retry attempts exhausted |
/// | [`CircuitOpenException`]    | Request blocked by open circuit |
/// | [`HttpTimeoutException`]    | Request exceeded timeout deadline |
/// | [`BulkheadRejectedException`] | Request rejected by concurrency limiter |
///
/// ## Design Principles
///
/// * **Null-safe Dart 3** — strict null safety, strict casts, strict inference
/// * **Immutable models** — `HttpRequest` and `HttpResponse` are `final` value types
/// * **No reflection** — zero use of `dart:mirrors`; tree-shaker friendly
/// * **Async-first** — every pipeline operation is `Future`-based
/// * **SOLID** — single responsibility per handler, open/closed via composition
/// * **Clean Architecture** — dependency arrows point inward
/// * **Deterministic disposal** — `dispose()` on policies, handlers, and clients

// ignore: unnecessary_library_name
library davianspace_http_resilience;

// Core
export 'src/core/core.dart';
// Exceptions
export 'src/exceptions/exceptions.dart';
// DI integration — ServiceCollection extensions for HttpClientFactory
export 'src/extensions/http_resilience_di_extensions.dart';
// Factory & client
export 'src/factory/factory.dart';
// Handlers
export 'src/handlers/handlers.dart';
// Pipeline — hide internal implementation details
export 'src/pipeline/pipeline.dart' hide HttpPipelineBuilder, TerminalHandler;
// Policies
export 'src/policies/policies.dart';
// Resilience (composable policy execution engine)
export 'src/resilience/resilience.dart';
// Utilities
export 'src/utils/utils.dart';
