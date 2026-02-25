# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.3] — 2026-02-25

### Added

- **`davianspace_dependencyinjection` integration** — `davianspace_dependencyinjection ^1.0.3`
  is now a runtime dependency. Two extension methods are added to `ServiceCollection`:
  - `addHttpClientFactory([configure])` — registers a singleton `HttpClientFactory`,
    optionally applying defaults and named-client setup. Uses try-add semantics.
  - `addTypedHttpClient<TClient>(create, {clientName, configure})` — registers
    `TClient` as a **transient** service backed by a named client on the shared
    `HttpClientFactory`. The factory is auto-registered if not already present.
    Configuration is applied via `onContainerBuilt` so the full container is
    assembled before any client is resolved.
- **`davianspace_logging` integration** — `logging` dependency replaced by
  `davianspace_logging ^1.0.3`. `LoggingHandler` now accepts
  `davianspace_logging.Logger` (injected or defaults to `NullLogger`).

### Changed

- **Removed `meta` dependency** — `@immutable` and `@internal` annotations dropped;
  `final class` declarations in Dart 3 already enforce immutability without the
  annotation.
- `LoggingHandler` default logger changed from `logging.Logger('davianspace.http')`
  to `NullLogger('davianspace.http')` — no-op until a `Logger` is injected.

---

## [1.0.2] — 2026-02-25

### Added

- **Rate limiter integration** — companion package `davianspace_http_ratelimit`
  v1.0.0 published. Adds `withRateLimit(RateLimitPolicy)` as a fluent extension
  on `HttpClientBuilder`, supporting six algorithms: Token Bucket, Fixed Window,
  Sliding Window (counter), Sliding Window Log, Leaky Bucket, and Concurrency
  Limiter. Server-side per-key admission control (`ServerRateLimiter`) is also
  included. Import `package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart`
  alongside this package to unlock the integration.
- **Example 10** — `example/example.dart` gains a rate limiter integration
  example demonstrating `TokenBucketRateLimiter`, `FixedWindowRateLimiter`, and
  the recommended pipeline placement of `withRateLimit`.

### Fixed

- **`TerminalHandler` false-positive analyzer warnings** — removed the redundant
  `@internal` annotation (and unused `package:meta` import) from `TerminalHandler`.
  The class is already hidden from public consumers via `hide TerminalHandler` in
  the main barrel; the annotation caused spurious
  `invalid_use_of_internal_member` warnings for in-package callers in
  `HttpPipeline`, `HttpPipelineBuilder`, and the test helper.
- **`doc/architecture.md` — `CircuitBreakerRegistry` API references** corrected:
  `isHealthy` and `snapshot` are read-only getters (not parameterised methods);
  the snippet now correctly shows `registry.isHealthy` (bool), `registry.snapshot`
  (`Map<String, CircuitState>`), and per-circuit access via `registry['name']`.
- **`README.md` — Health Checks & Monitoring** code example corrected to match
  the real `CircuitBreakerRegistry` getter API.
- **`pubspec.yaml` description** improved to mention all seven resilience policies
  within pub.dev's 180-character limit.

---

## [1.0.1] — 2026-02-24

### Added

**Resilience hardening**
* `ResiliencePolicy.dispose()` — virtual lifecycle method on the base class;
  enables deterministic cleanup of circuit-breaker timers, semaphore slots,
  and other stateful resources.
* `PolicyWrap.dispose()` — recursively disposes all child policies in a
  composed pipeline.
* `HttpClientBuilder.build()` — the `onDispose` callback now automatically
  disposes `PolicyHandler` policies when the client is disposed.
* `CircuitBreakerRegistry` health-check API — `isHealthy`, `snapshot`,
  `contains`, `[]` operator, and `circuitNames` for production monitoring.
* `RetryResiliencePolicy.onRetry` callback — fires on each retry attempt
  with the attempt number and exception for external telemetry integration.
* `RetryCallback` typedef — `void Function(int attempt, Object? exception)`.

**Configuration-driven hedging & fallback**
* `HedgingConfig` — typed config model for speculative request hedging
  (`hedgeAfterMs`, `maxHedgedAttempts`), parsed from JSON.
* `FallbackConfig` — typed config model for fallback trigger status codes,
  parsed from JSON.
* `ResilienceConfigLoader` — new `_parseHedging()` and `_parseFallback()`
  section parsers; full JSON support for all seven policy sections.
* `ResilienceConfigBinder.buildHedging()` — binds `HedgingConfig` →
  `HedgingPolicy`.
* `ResilienceConfigBinder.buildFallbackPolicy()` — binds `FallbackConfig` →
  `FallbackPolicy` with status-code-based predicate; the fallback action is
  always supplied programmatically.

**Per-request streaming**
* `HttpRequest.streamingKey` — well-known metadata constant
  (`'resilience.streaming'`) enabling per-request override of the pipeline's
  default streaming mode.
* `TerminalHandler.send()` — checks `context.request.metadata` for
  `HttpRequest.streamingKey` before falling back to the handler-level
  `streamingMode` default.

**Observability & security**
* `LoggingHandler` header redaction — new `redactedHeaders` and `logHeaders`
  constructor parameters; default redacted set includes `authorization`,
  `proxy-authorization`, `cookie`, `set-cookie`, and `x-api-key`.

### Changed

* `CircuitBreakerState` now uses `Stopwatch` for break-duration measurement,
  eliminating clock-skew sensitivity. `_openedAt` and `_lastTransitionAt`
  use `DateTime.now().toUtc()` for consistent serialisation.
* `BulkheadResiliencePolicy._AsyncSemaphore` — internal rewrite with
  `_SemaphoreEntry` wrapper and cancellation flag to prevent slot leakage
  under high-contention / timeout scenarios.
* `BulkheadPolicy._queue` — changed from `List<_QueueEntry>` to
  `Queue<_QueueEntry>` for O(1) dequeue operations.
* `CancellationToken.onCancelled` — the `Future<void>` is now memoised;
  repeated accesses return the same instance.
* `Backoff` strategies — shared `_defaultRandom` instance replaces per-call
  `math.Random()` allocations across all backoff implementations.
* `HttpStatusException.body` — capped at 64 KB; bodies exceeding the limit
  are truncated with a `… [truncated N bytes]` suffix to prevent
  unbounded memory consumption in diagnostic logging.
* `HttpResponse` class documentation — clarified as "effectively immutable"
  with a note about internal `_streamConsumed` tracking state.
* `HttpContext.startedAt` — documentation clarifies local-time-zone
  semantics and recommends `elapsed` for monotonic measurement.
* `CircuitBreakerResiliencePolicy` — enhanced class-level documentation
  covering lifecycle and `dispose()` contract.

### Fixed

* `BulkheadResiliencePolicy` — fixed semaphore slot leak when queued
  requests were cancelled or timed out before acquiring a permit.
* `RetryResiliencePolicy` — fixed `TypeError` when `retryForever: true`
  caused `totalAttempts` to be `null`; now defaults to `-1`.
* `RetryResiliencePolicy` — removed invalid `[attempt]` / `[exception]`
  doc-comment references that triggered `comment_references` lint info.

---

## [1.0.0] — 2026-01-15

First stable release. All public APIs are covered by semantic-versioning
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
* `ResiliencePipelineBuilder` — fluent DSL to construct `PolicyWrap` chains.
* `Policy` — static factory class: `Policy.retry`, `Policy.circuitBreaker`,
  `Policy.timeout`, `Policy.bulkhead`, `Policy.bulkheadIsolation`,
  `Policy.fallback`, `Policy.wrap`.
* `PolicyRegistry` — named-policy store for sharing instances across the app.
* `RetryContext` — per-attempt context carrying the attempt index and
  previous outcome, available to retry predicates.
* Backoff strategies: `ConstantBackoff`, `LinearBackoff`,
  `ExponentialBackoff`, `DecorrelatedJitterBackoff`, `AddedJitterBackoff`.
* `OutcomeClassifier` — pluggable result/exception → `PolicyOutcome` mapping.

**Observability (`ResilienceEventHub`)**
* `ResilienceEventHub` — broadcast stream for policy lifecycle events.
* Event types: `RetryAttemptEvent`, `CircuitStateChangedEvent`,
  `BulkheadRejectedEvent`, `TimeoutEvent`, `FallbackActivatedEvent`.
* `withEventHub()` extension on all resilience policies and handlers.

**Hedging handler**
* `HedgingPolicy` — configurable speculative request hedging for
  idempotent operations to reduce tail latency.
* `HedgingHandler` — pipeline handler that launches concurrent hedge
  requests after a configurable delay.

**Fallback handler**
* `FallbackPolicy` — configurable fallback action for the handler
  pipeline, triggered by exception or status-code predicates.
* `FallbackHandler` — pipeline handler that executes a fallback on
  downstream failure.

**Fluent builder DSL (`FluentHttpClientBuilder`)**
* `HttpClientFactoryFluentExtension` adds `.withResiliencePipeline()` and
  `.using()` to `HttpClientBuilder`.
* `FluentHttpClientBuilder` — immutable step-builder returning a new
  instance per decoration.

**JSON configuration layer**
* `ResilienceConfig` — typed configuration model for all policy parameters.
* `ResilienceConfigLoader` — resolves config from one or more
  `ResilienceConfigSource` implementations.
* `InMemoryConfigSource` — in-process config source backed by a `Map`.
* `JsonStringConfigSource` — parses raw JSON strings into `ResilienceConfig`.
* `ResilienceConfigBinder` — binds a loaded config to `ResiliencePolicy`
  instances using `PolicyRegistry`.
* `PolicyRegistryConfigExtension` — extension on `PolicyRegistry` for
  one-line binding: `registry.loadFromConfig(config)`.

**Bulkhead isolation handler**
* `BulkheadIsolationHandler` — handler-layer counterpart to
  `BulkheadIsolationResiliencePolicy`.
* Exposes live `activeCount`, `queuedCount`, and `semaphore` metrics.

**Streaming support**
* `TerminalHandler` supports `streamingMode` for unbuffered response
  bodies via `HttpResponse.bodyStream`.

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