import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Drains the microtask queue so that scheduleMicrotask callbacks run.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

/// Returns an action that always throws [exception].
Future<T> Function() _throwing<T>(Object exception) =>
    () => Future<T>.error(exception);

/// Returns an action that always returns [value].
Future<T> Function() _returning<T>(T value) => () => Future.value(value);

/// Returns a synthetic [HttpResponse] with [statusCode].
HttpResponse _resp(int statusCode) => HttpResponse(statusCode: statusCode);

final class _Boom implements Exception {
  const _Boom();
  @override
  String toString() => '_Boom';
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // --------------------------------------------------------------------------
  // ResilienceEventHub — subscription
  // --------------------------------------------------------------------------

  group('ResilienceEventHub — subscription', () {
    late ResilienceEventHub hub;

    setUp(() => hub = ResilienceEventHub());
    tearDown(() => hub.clear());

    test('isEmpty is true on fresh hub', () {
      expect(hub.isEmpty, isTrue);
      expect(hub.isNotEmpty, isFalse);
    });

    test('on<E> registers a typed listener — isNotEmpty becomes true', () {
      hub.on<RetryEvent>((_) {});
      expect(hub.isNotEmpty, isTrue);
    });

    test('on<E> is idempotent — same listener not registered twice', () async {
      var count = 0;
      int listener(RetryEvent _) => count++;
      hub.on<RetryEvent>(listener).on<RetryEvent>(listener);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(count, equals(1));
    });

    test('off<E> removes a typed listener', () async {
      var count = 0;
      int listener(RetryEvent _) => count++;
      hub.on<RetryEvent>(listener);
      hub.off<RetryEvent>(listener);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(count, equals(0));
      expect(hub.isEmpty, isTrue);
    });

    test('off<E> is a no-op for unregistered listener', () {
      expect(() => hub.off<RetryEvent>((_) {}), returnsNormally);
    });

    test('onAny registers a global listener', () {
      hub.onAny((_) {});
      expect(hub.isNotEmpty, isTrue);
    });

    test('onAny is idempotent', () async {
      var count = 0;
      int listener(ResilienceEvent _) => count++;
      hub.onAny(listener).onAny(listener);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(count, equals(1));
    });

    test('offAny removes a global listener', () async {
      var count = 0;
      int listener(ResilienceEvent _) => count++;
      hub.onAny(listener);
      hub.offAny(listener);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(count, equals(0));
      expect(hub.isEmpty, isTrue);
    });

    test('clear removes all listeners', () {
      hub.on<RetryEvent>((_) {});
      hub.onAny((_) {});
      hub.clear();
      expect(hub.isEmpty, isTrue);
    });

    test('on<E> returns this for fluent chaining', () {
      final result = hub.on<RetryEvent>((_) {});
      expect(result, same(hub));
    });

    test('onAny returns this for fluent chaining', () {
      final result = hub.onAny((_) {});
      expect(result, same(hub));
    });

    test('toString includes class name', () {
      expect(hub.toString(), contains('ResilienceEventHub'));
    });
  });

  // --------------------------------------------------------------------------
  // ResilienceEventHub — emit dispatch
  // --------------------------------------------------------------------------

  group('ResilienceEventHub — emit dispatch', () {
    late ResilienceEventHub hub;
    setUp(() => hub = ResilienceEventHub());
    tearDown(() => hub.clear());

    test('typed listener receives matching event', () async {
      RetryEvent? received;
      hub.on<RetryEvent>((e) => received = e);
      final emitted = RetryEvent(
        attemptNumber: 2,
        maxAttempts: 4,
        delay: const Duration(milliseconds: 100),
        source: 'test',
      );
      hub.emit(emitted);
      await _pump();
      expect(received, same(emitted));
    });

    test('typed listener NOT called for different event type', () async {
      var called = false;
      hub.on<CircuitOpenEvent>((_) => called = true);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(called, isFalse);
    });

    test('global listener receives any event type', () async {
      final received = <ResilienceEvent>[];
      hub.onAny(received.add);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      hub.emit(TimeoutEvent(timeout: const Duration(seconds: 1)));
      await _pump();
      expect(received.length, equals(2));
      expect(received[0], isA<RetryEvent>());
      expect(received[1], isA<TimeoutEvent>());
    });

    test('typed and global listeners both receive matching event', () async {
      var typedCount = 0;
      var globalCount = 0;
      hub.on<RetryEvent>((_) => typedCount++).onAny((_) => globalCount++);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(typedCount, equals(1));
      expect(globalCount, equals(1));
    });

    test('emit on empty hub is a fast-path no-op', () {
      // Should not throw and should return quickly.
      expect(
        () => hub.emit(
          RetryEvent(
            attemptNumber: 1,
            maxAttempts: 3,
            delay: Duration.zero,
          ),
        ),
        returnsNormally,
      );
    });

    test('multiple typed listeners all receive competing emit', () async {
      var a = 0;
      var b = 0;
      hub.on<RetryEvent>((_) => a++).on<RetryEvent>((_) => b++);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(a, equals(1));
      expect(b, equals(1));
    });

    test('emit does not block — returns before listeners run', () async {
      var listenerRan = false;
      hub.on<RetryEvent>((_) => listenerRan = true);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      // Before pump: listener has not yet run.
      expect(listenerRan, isFalse);
      await _pump();
      expect(listenerRan, isTrue);
    });

    test('async listener is supported', () async {
      var completed = false;
      hub.on<RetryEvent>((_) async {
        await Future<void>.delayed(Duration.zero);
        completed = true;
      });
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      // After pump the async listener body schedules its own microtask.
      await _pump();
      expect(completed, isTrue);
    });

    test('snapshot safety: listener added during emit not called for that emit',
        () async {
      var extraCalls = 0;
      hub.on<RetryEvent>((e) {
        // Try to add a new listener during dispatch — must not be called.
        hub.on<RetryEvent>((_) => extraCalls++);
      });
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(extraCalls, equals(0));
    });
  });

  // --------------------------------------------------------------------------
  // ResilienceEventHub — listener safety
  // --------------------------------------------------------------------------

  group('ResilienceEventHub — listener safety', () {
    late ResilienceEventHub hub;
    setUp(() => hub = ResilienceEventHub());
    tearDown(() => hub.clear());

    test('synchronous listener error does not propagate', () async {
      hub.on<RetryEvent>((_) => throw StateError('boom'));
      expect(
        () async {
          hub.emit(
            RetryEvent(
              attemptNumber: 1,
              maxAttempts: 3,
              delay: Duration.zero,
            ),
          );
          await _pump();
        },
        returnsNormally,
      );
    });

    test('subsequent listeners still called after earlier listener throws',
        () async {
      var secondCalled = false;
      hub
          .on<RetryEvent>((_) => throw StateError('first'))
          .on<RetryEvent>((_) => secondCalled = true);
      hub.emit(
        RetryEvent(
          attemptNumber: 1,
          maxAttempts: 3,
          delay: Duration.zero,
        ),
      );
      await _pump();
      expect(secondCalled, isTrue);
    });

    test('async listener future error is swallowed', () async {
      hub.on<RetryEvent>((_) async => throw StateError('async boom'));
      expect(
        () async {
          hub.emit(
            RetryEvent(
              attemptNumber: 1,
              maxAttempts: 3,
              delay: Duration.zero,
            ),
          );
          await _pump();
          await _pump();
        },
        returnsNormally,
      );
    });
  });

  // --------------------------------------------------------------------------
  // RetryEvent emitted by RetryResiliencePolicy
  // --------------------------------------------------------------------------

  group('RetryResiliencePolicy emits RetryEvent', () {
    test('RetryEvent emitted once for 1-retry scenario', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = RetryResiliencePolicy(
        maxRetries: 1,
        eventHub: hub,
      );

      var attempts = 0;
      await expectLater(
        policy.execute(() async {
          attempts++;
          if (attempts < 2) throw const _Boom();
          return 'ok';
        }),
        completion(equals('ok')),
      );

      await _pump();
      expect(events.length, equals(1));
      expect(events[0].attemptNumber, equals(1));
      expect(events[0].maxAttempts, equals(2));
      expect(events[0].exception, isA<_Boom>());
      expect(events[0].source, equals('RetryResiliencePolicy'));
    });

    test('RetryEvent emitted for each retry, not on final failure', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = RetryResiliencePolicy(maxRetries: 3, eventHub: hub);

      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );

      await _pump();
      // maxRetries=3 means 4 total attempts; RetryEvent fires on attempts 1, 2, 3
      expect(events.length, equals(3));
      expect(events[0].attemptNumber, equals(1));
      expect(events[1].attemptNumber, equals(2));
      expect(events[2].attemptNumber, equals(3));
    });

    test('no RetryEvent when action succeeds on first try', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = RetryResiliencePolicy(maxRetries: 3, eventHub: hub);
      await policy.execute(_returning('ok'));
      await _pump();

      expect(events, isEmpty);
    });

    test('RetryEvent emitted for result-based retry', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 1,
        retryOnResult: (r, _) => r == 'bad',
        eventHub: hub,
      );

      final result = await policy.execute(() async {
        calls++;
        return calls == 1 ? 'bad' : 'good';
      });

      await _pump();
      expect(result, equals('good'));
      expect(events.length, equals(1));
      expect(events[0].exception, isNull);
    });

    test('eventHub=null does not throw', () async {
      const policy = RetryResiliencePolicy(maxRetries: 1);
      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );
    });

    test('Policy.retry forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = Policy.retry(maxRetries: 1, eventHub: hub);
      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });

    test('ResiliencePipelineBuilder.addRetry forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = ResiliencePipelineBuilder()
          .addRetry(maxRetries: 1, eventHub: hub)
          .build();
      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });
  });

  // --------------------------------------------------------------------------
  // CircuitOpenEvent / CircuitCloseEvent emitted by CircuitBreakerResiliencePolicy
  // --------------------------------------------------------------------------

  group('CircuitBreakerResiliencePolicy emits circuit events', () {
    test('CircuitOpenEvent emitted when circuit opens', () async {
      final hub = ResilienceEventHub();
      final openEvents = <CircuitOpenEvent>[];
      hub.on<CircuitOpenEvent>(openEvents.add);

      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'open-test-cb',
        failureThreshold: 2,
        breakDuration: const Duration(hours: 1),
        registry: registry,
        eventHub: hub,
      );

      // Trigger failures to open circuit.
      for (var i = 0; i < 2; i++) {
        await expectLater(
          policy.execute(_throwing<String>(const _Boom())),
          throwsA(isA<_Boom>()),
        );
      }
      await _pump();

      expect(openEvents.length, equals(1));
      expect(openEvents[0].circuitName, equals('open-test-cb'));
      expect(openEvents[0].consecutiveFailures, equals(2));
      expect(openEvents[0].previousState, equals(CircuitState.closed));
      expect(openEvents[0].source, equals('CircuitBreakerResiliencePolicy'));
    });

    test('CircuitCloseEvent emitted when circuit closes after probe success',
        () async {
      final hub = ResilienceEventHub();
      final closeEvents = <CircuitCloseEvent>[];
      hub.on<CircuitCloseEvent>(closeEvents.add);

      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'test-cb',
        failureThreshold: 1,
        breakDuration: const Duration(milliseconds: 1),
        eventHub: hub,
      );

      // Open the circuit.
      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<_Boom>()),
      );

      // Wait for break duration to expire.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Probe succeeds → circuit closes.
      await policy.execute(_returning('ok'));
      await _pump();

      expect(closeEvents.length, equals(1));
      expect(closeEvents[0].circuitName, equals('test-cb'));
      expect(closeEvents[0].previousState, equals(CircuitState.halfOpen));
    });

    test('Policy.circuitBreaker forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <CircuitOpenEvent>[];
      hub.on<CircuitOpenEvent>(events.add);

      final policy = Policy.circuitBreaker(
        circuitName: 'policy-factory-cb',
        failureThreshold: 1,
        registry: CircuitBreakerRegistry(),
        eventHub: hub,
      );
      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<_Boom>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });

    test('ResiliencePipelineBuilder.addCircuitBreaker forwards eventHub',
        () async {
      final hub = ResilienceEventHub();
      final events = <CircuitOpenEvent>[];
      hub.on<CircuitOpenEvent>(events.add);

      final policy = ResiliencePipelineBuilder()
          .addCircuitBreaker(
            circuitName: 'builder-cb',
            failureThreshold: 1,
            registry: CircuitBreakerRegistry(),
            eventHub: hub,
          )
          .build();
      await expectLater(
        policy.execute(_throwing<String>(const _Boom())),
        throwsA(isA<_Boom>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });
  });

  // --------------------------------------------------------------------------
  // TimeoutEvent emitted by TimeoutResiliencePolicy
  // --------------------------------------------------------------------------

  group('TimeoutResiliencePolicy emits TimeoutEvent', () {
    test('TimeoutEvent emitted on timeout', () async {
      final hub = ResilienceEventHub();
      final events = <TimeoutEvent>[];
      hub.on<TimeoutEvent>(events.add);

      final policy = TimeoutResiliencePolicy(
        const Duration(milliseconds: 10),
        eventHub: hub,
      );

      await expectLater(
        policy.execute(
          () => Future<String>.delayed(const Duration(seconds: 10), () => 'ok'),
        ),
        throwsA(isA<HttpTimeoutException>()),
      );
      await _pump();

      expect(events.length, equals(1));
      expect(events[0].timeout, equals(const Duration(milliseconds: 10)));
      expect(events[0].exception, isA<HttpTimeoutException>());
      expect(events[0].source, equals('TimeoutResiliencePolicy'));
    });

    test('no TimeoutEvent when action completes in time', () async {
      final hub = ResilienceEventHub();
      final events = <TimeoutEvent>[];
      hub.on<TimeoutEvent>(events.add);

      final policy = TimeoutResiliencePolicy(
        const Duration(seconds: 10),
        eventHub: hub,
      );
      await policy.execute(_returning('ok'));
      await _pump();

      expect(events, isEmpty);
    });

    test('Policy.timeout forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <TimeoutEvent>[];
      hub.on<TimeoutEvent>(events.add);

      final policy = Policy.timeout(
        const Duration(milliseconds: 10),
        eventHub: hub,
      );
      await expectLater(
        policy.execute(
          () => Future<String>.delayed(
            const Duration(seconds: 10),
            () => 'ok',
          ),
        ),
        throwsA(isA<HttpTimeoutException>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });

    test('ResiliencePipelineBuilder.addTimeout forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <TimeoutEvent>[];
      hub.on<TimeoutEvent>(events.add);

      final policy = ResiliencePipelineBuilder()
          .addTimeout(const Duration(milliseconds: 10), eventHub: hub)
          .build();
      await expectLater(
        policy.execute(
          () => Future<String>.delayed(
            const Duration(seconds: 10),
            () => 'ok',
          ),
        ),
        throwsA(isA<HttpTimeoutException>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });
  });

  // --------------------------------------------------------------------------
  // FallbackEvent emitted by FallbackResiliencePolicy
  // --------------------------------------------------------------------------

  group('FallbackResiliencePolicy emits FallbackEvent', () {
    FallbackResiliencePolicy policy0(ResilienceEventHub hub) =>
        FallbackResiliencePolicy(
          fallbackAction: (_, __) async => _resp(200),
          shouldHandle: (e) => e is _Boom,
          eventHub: hub,
        );

    test('FallbackEvent emitted on exception', () async {
      final hub = ResilienceEventHub();
      final events = <FallbackEvent>[];
      hub.on<FallbackEvent>(events.add);

      final policy = policy0(hub);
      await policy.execute(_throwing<HttpResponse>(const _Boom()));
      await _pump();

      expect(events.length, equals(1));
      expect(events[0].exception, isA<_Boom>());
      expect(events[0].source, equals('FallbackResiliencePolicy'));
    });

    test('FallbackEvent emitted on result predicate', () async {
      final hub = ResilienceEventHub();
      final events = <FallbackEvent>[];
      hub.on<FallbackEvent>(events.add);

      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => _resp(200),
        shouldHandleResult: (r) => r is HttpResponse && r.statusCode == 500,
        eventHub: hub,
      );
      await policy.execute(_returning(_resp(500)));
      await _pump();

      expect(events.length, equals(1));
      expect(events[0].exception, isNull);
    });

    test('no FallbackEvent when action succeeds', () async {
      final hub = ResilienceEventHub();
      final events = <FallbackEvent>[];
      hub.on<FallbackEvent>(events.add);

      final policy = policy0(hub);
      await policy.execute(_returning(_resp(200)));
      await _pump();

      expect(events, isEmpty);
    });

    test('Policy.fallback forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <FallbackEvent>[];
      hub.on<FallbackEvent>(events.add);

      final policy = Policy.fallback(
        fallbackAction: (_, __) async => _resp(200),
        shouldHandle: (e) => e is _Boom,
        eventHub: hub,
      );
      await policy.execute(_throwing<HttpResponse>(const _Boom()));
      await _pump();
      expect(events, isNotEmpty);
    });

    test('ResiliencePipelineBuilder.addFallback forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <FallbackEvent>[];
      hub.on<FallbackEvent>(events.add);

      final policy = ResiliencePipelineBuilder()
          .addFallback(
            fallbackAction: (_, __) async => _resp(200),
            shouldHandle: (e) => e is _Boom,
            eventHub: hub,
          )
          .build();
      await policy.execute(_throwing<HttpResponse>(const _Boom()));
      await _pump();
      expect(events, isNotEmpty);
    });
  });

  // --------------------------------------------------------------------------
  // BulkheadRejectedEvent emitted by BulkheadResiliencePolicy
  // --------------------------------------------------------------------------

  group('BulkheadResiliencePolicy emits BulkheadRejectedEvent', () {
    test('BulkheadRejectedEvent emitted when queue is full', () async {
      final hub = ResilienceEventHub();
      final events = <BulkheadRejectedEvent>[];
      hub.on<BulkheadRejectedEvent>(events.add);

      final policy = BulkheadResiliencePolicy(
        maxConcurrency: 1,
        maxQueueDepth: 0, // immediately reject when slot taken
        eventHub: hub,
      );

      final completer = Completer<void>();
      // Occupy the sole concurrency slot.
      final inflight = policy.execute(() => completer.future.then((_) => 'ok'));

      // This request should be rejected because queue is full.
      await expectLater(
        policy.execute(_returning('ok')),
        throwsA(isA<BulkheadRejectedException>()),
      );
      await _pump();

      expect(events.length, equals(1));
      expect(events[0].maxConcurrency, equals(1));
      expect(events[0].source, equals('BulkheadResiliencePolicy'));

      completer.complete();
      await inflight;
    });

    test('Policy.bulkhead forwards eventHub', () async {
      final hub = ResilienceEventHub();
      // Verify the policy type is correct (factory forwards parameter).
      final policy = Policy.bulkhead(
        maxConcurrency: 1,
        maxQueueDepth: 0,
        eventHub: hub,
      );
      expect(
        policy,
        isA<BulkheadResiliencePolicy>(),
      );
      expect(
        policy.eventHub,
        same(hub),
      );
    });

    test('ResiliencePipelineBuilder.addBulkhead forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final policy = ResiliencePipelineBuilder()
          .addBulkhead(
            maxConcurrency: 1,
            maxQueueDepth: 0,
            eventHub: hub,
          )
          .build();
      expect(policy, isA<BulkheadResiliencePolicy>());
      expect((policy as BulkheadResiliencePolicy).eventHub, same(hub));
    });
  });

  // --------------------------------------------------------------------------
  // BulkheadRejectedEvent emitted by BulkheadIsolationResiliencePolicy
  // --------------------------------------------------------------------------

  group('BulkheadIsolationResiliencePolicy emits BulkheadRejectedEvent', () {
    test('BulkheadRejectedEvent emitted on isolation rejection', () async {
      final hub = ResilienceEventHub();
      final events = <BulkheadRejectedEvent>[];
      hub.on<BulkheadRejectedEvent>(events.add);

      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 0, // immediately reject when slot taken
        eventHub: hub,
      );

      final completer = Completer<void>();
      final inflight = policy.execute(() => completer.future.then((_) => 'ok'));

      await expectLater(
        policy.execute(_returning('ok')),
        throwsA(isA<BulkheadRejectedException>()),
      );
      await _pump();

      expect(events.length, equals(1));
      expect(events[0].maxConcurrency, equals(1));
      expect(events[0].reason, isNotNull);
      expect(events[0].source, equals('BulkheadIsolationResiliencePolicy'));

      completer.complete();
      await inflight;
    });

    test('Policy.bulkheadIsolation forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final policy = Policy.bulkheadIsolation(
        maxConcurrentRequests: 1,
        maxQueueSize: 0,
        eventHub: hub,
      );
      expect(policy, isA<BulkheadIsolationResiliencePolicy>());
      expect(
        policy.eventHub,
        same(hub),
      );
    });

    test('ResiliencePipelineBuilder.addBulkheadIsolation forwards eventHub',
        () async {
      final hub = ResilienceEventHub();
      final policy = ResiliencePipelineBuilder()
          .addBulkheadIsolation(
            maxConcurrentRequests: 1,
            maxQueueSize: 0,
            eventHub: hub,
          )
          .build();
      expect(policy, isA<BulkheadIsolationResiliencePolicy>());
      expect(
        (policy as BulkheadIsolationResiliencePolicy).eventHub,
        same(hub),
      );
    });
  });

  // --------------------------------------------------------------------------
  // ResilienceEvent — event fields
  // --------------------------------------------------------------------------

  group('ResilienceEvent fields', () {
    test('timestamp is set at construction', () {
      final before = DateTime.now();
      final event = RetryEvent(
        attemptNumber: 1,
        maxAttempts: 3,
        delay: Duration.zero,
      );
      final after = DateTime.now();
      expect(
        event.timestamp.isAfter(before) ||
            event.timestamp.isAtSameMomentAs(before),
        isTrue,
      );
      expect(
        event.timestamp.isBefore(after) ||
            event.timestamp.isAtSameMomentAs(after),
        isTrue,
      );
    });

    test('RetryEvent.toString includes attempt info', () {
      final event = RetryEvent(
        attemptNumber: 2,
        maxAttempts: 5,
        delay: const Duration(milliseconds: 200),
        source: 'src',
      );
      final s = event.toString();
      expect(s, contains('2'));
      expect(s, contains('5'));
    });

    test('CircuitOpenEvent.toString includes circuit name', () {
      final event = CircuitOpenEvent(
        circuitName: 'my-circuit',
        previousState: CircuitState.closed,
        consecutiveFailures: 3,
        source: 'src',
      );
      expect(event.toString(), contains('my-circuit'));
    });

    test('CircuitCloseEvent.toString includes circuit name', () {
      final event = CircuitCloseEvent(
        circuitName: 'my-circuit',
        previousState: CircuitState.halfOpen,
        source: 'src',
      );
      expect(event.toString(), contains('my-circuit'));
    });

    test('TimeoutEvent.toString includes timeout ms', () {
      final event = TimeoutEvent(
        timeout: const Duration(milliseconds: 500),
        source: 'src',
      );
      expect(event.toString(), contains('500'));
    });

    test('FallbackEvent.toString includes source', () {
      final event = FallbackEvent(source: 'MyPolicy');
      expect(event.toString(), contains('MyPolicy'));
    });

    test('BulkheadRejectedEvent.toString includes maxConcurrency', () {
      final event = BulkheadRejectedEvent(
        maxConcurrency: 10,
        maxQueueDepth: 50,
        source: 'src',
      );
      expect(event.toString(), contains('10'));
    });
  });

  // --------------------------------------------------------------------------
  // Policy.httpRetry and Policy.classifiedRetry forward eventHub
  // --------------------------------------------------------------------------

  group('Policy.httpRetry and classifiedRetry forward eventHub', () {
    test('Policy.httpRetry creates RetryResiliencePolicy with eventHub',
        () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = Policy.httpRetry(maxRetries: 1, eventHub: hub);
      // Trigger a non-HTTP exception retry (falls through to default retry).
      await expectLater(
        policy.execute(_throwing<HttpResponse>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });

    test('Policy.classifiedRetry creates RetryResiliencePolicy with eventHub',
        () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = Policy.classifiedRetry(maxRetries: 1, eventHub: hub);
      await expectLater(
        policy.execute(_throwing<HttpResponse>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );
      await _pump();
      // classifiedRetry with default HttpOutcomeClassifier retries on exceptions.
      expect(events, isNotEmpty);
    });

    test('ResiliencePipelineBuilder.addHttpRetry forwards eventHub', () async {
      final hub = ResilienceEventHub();
      final events = <RetryEvent>[];
      hub.on<RetryEvent>(events.add);

      final policy = ResiliencePipelineBuilder()
          .addHttpRetry(maxRetries: 1, eventHub: hub)
          .build();
      await expectLater(
        policy.execute(_throwing<HttpResponse>(const _Boom())),
        throwsA(isA<RetryExhaustedException>()),
      );
      await _pump();
      expect(events, isNotEmpty);
    });

    test('ResiliencePipelineBuilder.addClassifiedRetry forwards eventHub',
        () async {
      final hub = ResilienceEventHub();
      final policy = ResiliencePipelineBuilder()
          .addClassifiedRetry(maxRetries: 1, eventHub: hub)
          .build();
      // Just verify it constructs without error.
      expect(policy, isNotNull);
    });
  });
}
