/// davianspace_http_resilience
///
/// A production-ready Dart/Flutter HTTP resilience library inspired by
/// **Microsoft.Extensions.Http** and **Microsoft.Extensions.Http.Resilience**.
///
/// Provides a fully composable middleware pipeline with Polly-style resilience
/// policies — all built on clean-architecture and SOLID principles, with no
/// reflection and full null-safety.
///
/// ## Quick start
///
/// ```dart
/// import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
///
/// void main() async {
///   final client = HttpClientFactory.create('demo')
///       .withBaseUri(Uri.parse('https://jsonplaceholder.typicode.com'))
///       .withDefaultHeader('Accept', 'application/json')
///       .withLogging()
///       .withRetry(RetryPolicy.exponential(maxRetries: 3, useJitter: true))
///       .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'demo'))
///       .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10)))
///       .build();
///
///   final response = await client.get(Uri.parse('/todos/1'));
///   print(response.ensureSuccess().bodyAsString);
/// }
/// ```
///
/// ## Architecture overview
///
/// ```
/// Application code
///       │
///       ▼
/// ResilientHttpClient        — ergonomic verb methods (get / post / …)
///       │
///       ▼
/// HttpHandler pipeline       — ordered chain of DelegatingHandler instances
///   ┌─────────────────────┐
///   │ LoggingHandler      │  1. outermost — logs full round-trip
///   │ RetryHandler        │  2. retries transient failures
///   │ CircuitBreakerHandler│ 3. rejects when threshold exceeded
///   │ TimeoutHandler      │  4. deadline per attempt
///   │ BulkheadHandler     │  5. limits concurrency
///   │ TerminalHandler     │  6. real HTTP I/O (package:http)
///   └─────────────────────┘
/// ```
///
/// ## Key types
///
/// | Type                    | Role |
/// |-------------------------|------|
/// | [`HttpRequest`]           | Immutable outgoing request model |
/// | [`HttpResponse`]          | Immutable response model |
/// | [`HttpContext`]           | Mutable per-request execution context |
/// | [`HttpHandler`]           | Abstract pipeline unit |
/// | [`DelegatingHandler`]     | Middleware base with inner-handler chaining |
/// | [`RetryPolicy`]           | Constant / linear / exponential back-off |
/// | [`CircuitBreakerPolicy`]  | Failure-threshold circuit control |
/// | [`TimeoutPolicy`]         | Per-attempt timeout |
/// | [`BulkheadPolicy`]        | Max-concurrency + queue isolation |
/// | [`HttpClientFactory`]     | Instance-based named + typed client factory |
/// | [`HttpClientBuilder`]     | Fluent pipeline builder for [`ResilientHttpClient`] |
/// | [`PolicyHandler`]         | Bridge: applies [`ResiliencePolicy`] inside a pipeline |
/// | [`ResilientHttpClient`]   | High-level HTTP client with verb helpers |
/// | [`ResiliencePolicy`]      | Abstract composable policy base |
/// | [`RetryResiliencePolicy`] | Free-standing retry with back-off |
/// | [`Policy`]                | Static factory for all resilience policies |
/// | [`PolicyWrap`]            | Ordered multi-policy pipeline with introspection |
/// | [`ResiliencePipelineBuilder`] | Fluent builder for composing policies |
/// | [`PolicyRegistry`]        | Named policy store with typed resolution |
/// | [`OutcomeClassifier`]     | Classifies HTTP outcomes as success / transient / permanent |
/// | [`HttpOutcomeClassifier`] | Default HTTP outcome classifier (2xx/4xx/5xx) |
/// | [`OutcomeClassification`] | Enum: success, transientFailure, permanentFailure |
/// | [`FallbackPolicy`]        | Fallback configuration for the handler pipeline |
/// | [`FallbackResiliencePolicy`] | Free-standing fallback policy for `Policy.execute` |
/// | [`FallbackHandler`]       | Handler that executes a fallback on pipeline failure |
/// | [`BulkheadIsolationPolicy`] | Efficient bulkhead config (HTTP-oriented names) |
/// | [`BulkheadIsolationResiliencePolicy`] | Free-standing isolation policy with zero-polling semaphore |
/// | [`BulkheadIsolationHandler`] | Handler that enforces isolation via `BulkheadIsolationSemaphore` |
/// | [`BulkheadIsolationSemaphore`] | Completer-based async semaphore for concurrency control |
/// | [`BulkheadRejectionReason`] | Enum: queueFull \| queueTimeout |
/// | [`FluentHttpClientBuilder`] | Immutable fluent DSL for building clients with resilience policies |
/// | [`HttpClientFactoryFluentExtension`] | Extension adding `forClient()` to [`HttpClientFactory`] |
/// | [`ResilienceConfig`]        | Immutable top-level config model parsed from JSON |
/// | [`RetryConfig`]             | Config section for a retry policy |
/// | [`TimeoutConfig`]           | Config section for a timeout policy |
/// | [`Subscription`]            | Opaque handle returned by `addStateChangeListener`; call `cancel()` to deregister |
/// | [`CircuitBreakerConfig`]    | Config section for a circuit-breaker policy |
/// | [`BulkheadConfig`]          | Config section for a bulkhead policy |
/// | [`BulkheadIsolationConfig`] | Config section for a bulkhead-isolation policy |
/// | [`BackoffConfig`]           | Config section describing a back-off strategy |
/// | [`BackoffType`]             | Enum of supported back-off algorithms |
/// | [`ResilienceConfigLoader`]  | Parses JSON → [`ResilienceConfig`] |
/// | [`ResilienceConfigSource`]  | Abstraction for static/dynamic config sources |
/// | [`JsonStringConfigSource`]  | Static config source backed by a JSON string |
/// | [`InMemoryConfigSource`]    | Dynamic config source with live-update support |
/// | [`ResilienceConfigBinder`]  | Binds [`ResilienceConfig`] → [`ResiliencePolicy`] instances |
/// | [`PolicyRegistryConfigExtension`] | Extension: load config directly into [`PolicyRegistry`] |
/// | [`ResilienceEventHub`]      | Centralized event bus; dispatches via scheduleMicrotask |
/// | [`ResilienceEvent`]         | Sealed base class for all resilience lifecycle events |
/// | [`RetryEvent`]              | Emitted on each retry attempt |
/// | [`CircuitOpenEvent`]        | Emitted when circuit breaker opens |
/// | [`CircuitCloseEvent`]       | Emitted when circuit breaker closes |
/// | [`TimeoutEvent`]            | Emitted when a timeout occurs |
/// | [`FallbackEvent`]           | Emitted when a fallback triggers |
/// | [`BulkheadRejectedEvent`]   | Emitted when bulkhead rejects a request |

// ignore: unnecessary_library_name
library davianspace_http_resilience;

// Core
export 'src/core/core.dart';
// Exceptions
export 'src/exceptions/exceptions.dart';
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
