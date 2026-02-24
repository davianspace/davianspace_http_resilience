## 1.0.0

First stable release. All APIs are now covered by semantic-versioning
guarantees.

### Added

**Resilience policy engine (`ResiliencePolicy`)**
* Abstract `ResiliencePolicy` base with generic `execute<T>()` contract.
* `RetryResiliencePolicy` — stateless retry with constant, linear,
  exponential, and decorrelated-jitter back-off strategies.
* `CircuitBreakerResiliencePolicy` — Closed / Open / Half-Open state machine
  with configurable failure threshold, sampling window, and open duration.
* `TimeoutResiliencePolicy` — cancels actions after a configurable deadline.
* `BulkheadResiliencePolicy` — bounded-concurrency semaphore with observable
  `activeCount` and `queuedCount` metrics.
* `BulkheadIsolationResiliencePolicy` — `BulkheadIsolationSemaphore`-backed
  isolation policy with queue-timeout and rejection callbacks.
* `FallbackResiliencePolicy` — response/exception predicate + async fallback
  action.
* `PolicyWrap` — combines an ordered list of `ResiliencePolicy` instances.
* `ResiliencePipelineBuilder` fluent DSL to construct `PolicyWrap` chains.
* `Policy` static factory class: `Policy.retry`, `Policy.circuitBreaker`,
  `Policy.timeout`, `Policy.bulkhead`, `Policy.bulkheadIsolation`,
  `Policy.fallback`, `Policy.wrap`.
* `PolicyRegistry` — named-policy store for sharing instances across the app.
* `RetryContext` — per-attempt context carrying the attempt index and
  previous outcome, available to retry predicates.
* Backoff strategies: `ConstantBackoff`, `LinearBackoff`,
  `ExponentialBackoff`, `DecorrelatedJitterBackoff`, `AddedJitterBackoff`.
* `OutcomeClassifier` — pluggable result/exception → `PolicyOutcome` mapping.

**Observability (`ResilienceEventHub`)**
* `ResilienceEventHub` broadcast stream for policy lifecycle events.
* Event types: `RetryAttemptEvent`, `CircuitStateChangedEvent`,
  `BulkheadRejectedEvent`, `TimeoutEvent`, `FallbackActivatedEvent`.
* `withEventHub()` extension on all resilience policies and handlers.

**Fluent builder DSL (`FluentHttpClientBuilder`)**
* `HttpClientFactoryFluentExtension` adds `.withResiliencePipeline()` and
  `.using()` to `HttpClientBuilder`.
* `FluentHttpClientBuilder` immutable step-builder returning a new instance
  per decoration.

**JSON configuration layer**
* `ResilienceConfig` — typed configuration model for all policy parameters.
* `ResilienceConfigLoader` — resolves config from one or more
  `ResilienceConfigSource` implementations.
* `InMemoryConfigSource` — in-process config source backed by a `Map`.
* `JsonStringConfigSource` — parses raw JSON strings into `ResilienceConfig`.
* `ResilienceConfigBinder` — binds a loaded config to `ResiliencePolicy`
  instances using `PolicyRegistry`.
* `PolicyRegistryConfigExtension` — extension on `PolicyRegistry` for
  one-line binding: `registry.bindFromConfig(config)`.

**Bulkhead isolation handler**
* `BulkheadIsolationHandler` — handler-layer counterpart to
  `BulkheadIsolationResiliencePolicy`.
* Exposes live `activeCount`, `queuedCount`, and `semaphore` metrics.

### Changed

* **`HttpStatusException`** now extends `HttpResilienceException` (previously
  implemented `Exception` directly), enabling unified catch with
  `on HttpResilienceException`.
* **`TerminalHandler`** and **`HttpPipelineBuilder`** have been annotated
  `@internal`: they remain exported for internal use but produce a lint
  warning if referenced outside the package. Use `HttpClientFactory` /
  `HttpClientBuilder.addHandler()` instead.

### Fixed

* Stack traces are fully preserved via `Error.throwWithStackTrace` throughout
  retry and pipeline code.
* `BulkheadRejectedException` carries both `maxConcurrency` and
  `maxQueueDepth` fields for accurate diagnostic messages.

---

## 0.1.0

* Initial release.
* Composable `HttpHandler` pipeline with `DelegatingHandler` chaining.
* `RetryHandler` with constant, linear, and exponential (jitter) back-off.
* `CircuitBreakerHandler` with Closed / Open / Half-Open state machine and
  application-scoped `CircuitBreakerRegistry`.
* `TimeoutHandler` with per-attempt or total-operation deadline.
* `BulkheadHandler` with configurable concurrency cap and queue depth.
* `LoggingHandler` via `package:logging`.
* `ResilientHttpClient` with `get`, `post`, `put`, `patch`, `delete` verbs.
* `HttpClientFactory` named-client registry.
* `CancellationToken` cooperative cancellation.
* `RetryPredicates` DSL with `.or()` / `.and()` combinators.
* `HttpResponseExtensions` with `ensureSuccess()`, `bodyAsString`,
  `bodyAsJsonMap`, `bodyAsJsonList`.
* Full `dart analyze` clean (strict mode).
