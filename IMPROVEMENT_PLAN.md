# Improvement Plan — davianspace_http_resilience v1.0.0

Generated: 2026-02-24  
Baseline: `dart analyze --fatal-infos` clean, 788/788 tests passing

---

## Phase 1 — Correctness Fixes (bugs with wrong observable behaviour)

These three issues silently produce wrong results today.

### Task 1.1 — Fix `BulkheadSemaphore` spin-wait

**File:** `lib/src/policies/bulkhead_policy.dart`

Replace `_QueueEntry` (the `while (!done) await Future.delayed(50µs)` loop) with an
identical `Completer<void>`-based approach already used by `BulkheadIsolationSemaphore`.
The `BulkheadSemaphore` public surface (`running`, `queued`, `acquire()`, `release()`)
stays unchanged. No changes to `BulkheadHandler`, `BulkheadPolicy`, or any test.

---

### Task 1.2 — Fix `CircuitBreakerHandler` missing `recordRejected()`

**File:** `lib/src/handlers/circuit_breaker_handler.dart`

Add `_state.recordRejected()` immediately before the `throw CircuitOpenException(...)` line.
Two-line change. No API changes.

---

### Task 1.3 — Fix cancellation during retry delay

**Files:** `lib/src/handlers/retry_handler.dart`, `lib/src/resilience/retry_resilience_policy.dart`

Replace bare `await Future<void>.delayed(delay)` with a race:

```dart
await Future.any([
  Future<void>.delayed(delay),
  context.cancellationToken.onCancelled,   // RetryHandler path
  cancellationToken?.onCancelled ?? Future<void>.delayed(delay), // Policy path
]);
context.throwIfCancelled();
```

The `onCancelled` getter already exists on `CancellationToken`. No API changes.

---

## Phase 2 — Resource Management (production server safety)

### Task 2.1 — Add `dispose()` to `ResilientHttpClient` and `HttpClientFactory`

**Files:** `lib/src/factory/resilient_http_client.dart`,
`lib/src/pipeline/terminal_handler.dart`,
`lib/src/factory/http_client_factory.dart`

Execution:
1. `TerminalHandler` gets a `dispose()` that calls `_client.close()` if the client was
   internally created (not injected externally — add a `bool _ownsClient` flag).
2. `ResilientHttpClient` gets a `dispose()` that walks down its pipeline looking for
   `TerminalHandler` and calls `dispose()` on it.
3. `HttpClientFactory` gets a `dispose()` that calls `dispose()` on every registered client.

No changes to builder fluent API.

---

### Task 2.2 — Fix circuit-breaker listener leak

**File:** `lib/src/policies/circuit_breaker_policy.dart`

Change `addStateChangeListener` to return an opaque `Subscription` object with a single
`cancel()` method that removes the listener from the internal list. Keep the existing
method signature working (no breaking change). Callers who don't use the return value
are unaffected; callers who need cleanup now can.

```dart
Subscription addStateChangeListener(CircuitStateChangeCallback callback) { ... }

abstract final class Subscription {
  void cancel();
}
```

---

## Phase 3 — Security & Logging

### Task 3.1 — URI sanitization in `LoggingHandler`

**File:** `lib/src/handlers/logging_handler.dart`

Add an optional `uriSanitizer` parameter:

```dart
LoggingHandler({
  Logger? logger,
  String Function(Uri)? uriSanitizer,
})
```

Default behaviour: strip query parameters (`uri.replace(queryParameters: const {})`),
so secrets in query strings are not logged by default. Callers who need the full URI
pass `uriSanitizer: (u) => u.toString()`. No breaking change — existing calls with no
argument get the safe default.

---

### Task 3.2 — Fix `ensureSuccess()` eager body decode / memory retention

**Files:** `lib/src/utils/http_response_extensions.dart`,
`lib/src/exceptions/http_status_exception.dart`

Change `HttpStatusException` to store `List<int>?` (the raw bytes) rather than `String?`.
Expose `body` as a lazy getter that calls `utf8.decode()` on first access:

```dart
final class HttpStatusException extends HttpResilienceException {
  HttpStatusException({required this.statusCode, List<int>? bodyBytes})
      : _bodyBytes = bodyBytes, ...

  String? get body =>
      _bodyBytes == null ? null : utf8.decode(_bodyBytes!, allowMalformed: true);
}
```

Update `ensureSuccess()` to pass `bodyBytes: body` (raw bytes). The `body` getter name
is preserved — callers calling `e.body` get the same `String?` as before. No breaking change.

---

### Task 3.3 — Fix `RetryPredicates.networkErrors` over-catching

**File:** `lib/src/utils/retry_predicates.dart`

Narrow the predicate to known transient I/O exception types from `dart:io`:

```dart
static RetryPredicate get networkErrors =>
    (response, exception, __) =>
        exception is SocketException ||
        exception is HttpException   ||
        exception is OSError;
```

Add a new broader predicate `RetryPredicates.anyException` for callers who want the old
all-exceptions behaviour. Existing code using `networkErrors` is brought to the correct
semantic; callers who needed the old catch-all can opt in explicitly.

---

## Phase 4 — Performance

### Task 4.1 — Cache `UnmodifiableMapView` in `HttpRequest` and `HttpResponse`

**Files:** `lib/src/core/http_request.dart`, `lib/src/core/http_response.dart`

Change the `headers` and `metadata` getters to return a cached `UnmodifiableMapView`
created once at construction time. The existing field `_headers` becomes `_headersView`
created in the initializer list. No API change — getters return the same `Map<String, String>` type.

---

### Task 4.2 — Replace `DateTime.now()` with `Stopwatch` in `HttpContext`

**File:** `lib/src/core/http_context.dart`

Replace:

```dart
final DateTime startedAt = DateTime.now();
Duration get elapsed => DateTime.now().difference(startedAt);
```

With:

```dart
final Stopwatch _stopwatch = Stopwatch()..start();
Duration get elapsed => _stopwatch.elapsed;
```

`startedAt` is still useful for absolute timestamps in logging; keep it as a
`DateTime.now()` snapshot at construction (one call, not repeated). The `elapsed`
getter becomes allocation-free and uses a monotonic clock.

---

## Phase 5 — Resilience Behaviour Gaps

### Task 5.1 — `Retry-After` header support

**File:** `lib/src/policies/retry_policy.dart` (new field + doc),
`lib/src/handlers/retry_handler.dart`

Add `bool respectRetryAfterHeader = false` to `RetryPolicy`. When `true`, the retry
handler checks the `Retry-After` response header (numeric seconds or HTTP-date) and uses
that delay instead of the computed backoff, capped at `maxDelay` if defined. This is
purely additive — existing policies are unaffected.

---

### Task 5.2 — Add timeout cancellation signal

**File:** `lib/src/handlers/timeout_handler.dart`

After the `TimeoutException` fires and before rethrowing `HttpTimeoutException`, call:

```dart
context.cancellationToken.cancel('timeout');
```

This allows downstream handlers to cooperatively stop work. The call is a no-op if
already cancelled. One-line addition.

---

### Task 5.3 — `RetryHandler` parity: add `CancellationToken` support

**Files:** `lib/src/policies/retry_policy.dart`, `lib/src/handlers/retry_handler.dart`

Add `CancellationToken? cancellationToken` to `RetryPolicy`. The `RetryHandler` reads it
alongside `context.cancellationToken`, using a merged check:

```dart
if (policy.cancellationToken?.isCancelled ?? false) {
  throw CancellationException();
}
```

This closes the capability gap between the two policy worlds without merging them.

---

## Phase 6 — API Completeness

### Task 6.1 — Add `HEAD` and `OPTIONS` verbs to `ResilientHttpClient`

**File:** `lib/src/factory/resilient_http_client.dart`

Add `head()` and `options()` methods as thin delegations to `_send()`, exactly mirroring
`get()` and `delete()`. Add corresponding entries to `HttpMethod` enum if not present.

---

### Task 6.2 — Structured logging option for `LoggingHandler`

**File:** `lib/src/handlers/logging_handler.dart`

Add `bool structured = false` parameter. When `true`, log messages are emitted as
JSON strings:

```json
{"event":"response","method":"GET","uri":"...","status":200,"durationMs":142,"retryCount":0}
```

Structured output uses the same `Logger`/`Level` system; only the message format changes.
Fully backwards-compatible.

---

### Task 6.3 — Sliding-window circuit breaker option

**File:** `lib/src/policies/circuit_breaker_policy.dart`

Add `CircuitBreakerWindowMode { consecutive, slidingWindow }` and two new optional
parameters to `CircuitBreakerPolicy`:

```dart
final CircuitBreakerWindowMode windowMode;  // default: consecutive (no change)
final int windowSize;                        // only used in slidingWindow mode
```

In `CircuitBreakerState.recordSuccess()` / `recordFailure()`, when
`windowMode == slidingWindow`, maintain a fixed-size circular buffer of outcomes and
compute the failure ratio over the buffer. Default mode is `consecutive`, so existing
behaviour is completely unchanged.

---

## Phase 7 — Minor Gaps and Polish

### Task 7.1 — `ResilienceEventHub` listener error callback

**File:** `lib/src/observability/resilience_event_hub.dart`

Add `void Function(Object error, StackTrace st)? onListenerError` parameter to the
`ResilienceEventHub` constructor. When set, listener exceptions are routed there instead
of silently discarded. Default is null (existing silent behaviour preserved).

---

### Task 7.2 — `PolicyRegistry` namespace isolation

**File:** `lib/src/resilience/policy_registry.dart`

Add an optional `String namespace = ''` parameter to the constructor. All `add`/`get`
keys are internally prefixed with `'$namespace:'`. The default (empty string) preserves
existing keys and behaviour:

```dart
final tenantRegistry = PolicyRegistry(namespace: 'tenant-A');
```

---

## Execution Order & Dependencies

```
Phase 1  (1.1, 1.2, 1.3)     — no cross-dependencies, implement in parallel
Phase 2  (2.1, 2.2)           — independent of each other
Phase 3  (3.1, 3.2, 3.3)     — independent of each other
Phase 4  (4.1, 4.2)           — independent of each other
Phase 5  (5.1, 5.2, 5.3)     — 5.3 conceptually follows Phase 1 task 1.3
Phase 6  (6.1, 6.2, 6.3)     — independent, low risk
Phase 7  (7.1, 7.2)           — independent polish
```

---

## Deliberate Exclusions

| Feature | Reason deferred |
|---------|-----------------|
| Response streaming | Requires breaking `HttpResponse.body: List<int>?` → `Stream<List<int>>?` — suitable for v2.0 |
| Rate limiting | Out of scope for a resilience library; better as a companion package (`davianspace_http_ratelimit`) |
| Hedging policy | Needs significant internal pipeline changes; mark as future work for v1.x |
| Architecture unification | Pipeline handler world and policy engine world are correctly bridged via `PolicyHandler`; merge is a major refactor. Close capability gaps in Phase 5 instead |

---

## Impact Summary

| Phase | Tasks | Risk | Testing effort |
|-------|-------|------|----------------|
| 1 | 3 | Low — targeted fixes | Update ~5 existing tests, add ~6 new |
| 2 | 2 | Low — additive | Add ~8 new tests |
| 3 | 3 | Low — additive + narrow predicate | Add ~6 new tests |
| 4 | 2 | Very low — internal only | No new tests needed |
| 5 | 3 | Low — additive fields | Add ~10 new tests |
| 6 | 3 | Low — additive | Add ~8 new tests |
| 7 | 2 | Very low — additive | Add ~4 new tests |
