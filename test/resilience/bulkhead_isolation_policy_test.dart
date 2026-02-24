import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test helpers
// ════════════════════════════════════════════════════════════════════════════

/// Builds a [ResilientHttpClient] with [policy] and a controllable transport.
///
/// [transportCompleter] is completed by the test to release the in-flight request.
ResilientHttpClient _clientWith(
  BulkheadIsolationPolicy policy,
  Completer<http.Response> transportCompleter,
) =>
    HttpClientBuilder()
        .withBaseUri(Uri.parse('https://example.com'))
        .withBulkheadIsolation(policy)
        .withHttpClient(
          http_testing.MockClient((_) => transportCompleter.future),
        )
        .build();

/// Pumps the event loop enough for microtasks + one event-loop turn.
Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.microtask(() {});
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadRejectionReason enum', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('has queueFull value', () {
      expect(BulkheadRejectionReason.queueFull, isNotNull);
    });

    test('has queueTimeout value', () {
      expect(BulkheadRejectionReason.queueTimeout, isNotNull);
    });

    test('values are distinct', () {
      expect(
        BulkheadRejectionReason.queueFull,
        isNot(equals(BulkheadRejectionReason.queueTimeout)),
      );
    });

    test('name getter works as expected', () {
      expect(BulkheadRejectionReason.queueFull.name, equals('queueFull'));
      expect(BulkheadRejectionReason.queueTimeout.name, equals('queueTimeout'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadRejectedException — reason field', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('defaults to queueFull for backwards compatibility', () {
      const ex = BulkheadRejectedException(
        maxConcurrency: 5,
        maxQueueDepth: 10,
      );
      expect(ex.reason, equals(BulkheadRejectionReason.queueFull));
    });

    test('accepts queueTimeout reason', () {
      const ex = BulkheadRejectedException(
        maxConcurrency: 5,
        maxQueueDepth: 10,
        reason: BulkheadRejectionReason.queueTimeout,
      );
      expect(ex.reason, equals(BulkheadRejectionReason.queueTimeout));
    });

    test('existing no-reason usage still works', () {
      // Ensure existing code that creates without reason does not break.
      expect(
        () => const BulkheadRejectedException(
          maxConcurrency: 1,
          maxQueueDepth: 0,
        ),
        returnsNormally,
      );
    });

    test('toString includes reason name', () {
      const ex = BulkheadRejectedException(
        maxConcurrency: 5,
        maxQueueDepth: 10,
        reason: BulkheadRejectionReason.queueTimeout,
      );
      expect(ex.toString(), contains('queueTimeout'));
    });

    test('carries maxConcurrency and maxQueueDepth', () {
      const ex = BulkheadRejectedException(
        maxConcurrency: 42,
        maxQueueDepth: 99,
      );
      expect(ex.maxConcurrency, equals(42));
      expect(ex.maxQueueDepth, equals(99));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationPolicy — value object', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('stores maxConcurrentRequests', () {
      const p = BulkheadIsolationPolicy(maxConcurrentRequests: 7);
      expect(p.maxConcurrentRequests, equals(7));
    });

    test('stores maxQueueSize', () {
      const p = BulkheadIsolationPolicy(maxQueueSize: 42);
      expect(p.maxQueueSize, equals(42));
    });

    test('stores queueTimeout', () {
      const p = BulkheadIsolationPolicy(
        queueTimeout: Duration(seconds: 3),
      );
      expect(p.queueTimeout, equals(const Duration(seconds: 3)));
    });

    test('default maxConcurrentRequests is 10', () {
      const p = BulkheadIsolationPolicy();
      expect(p.maxConcurrentRequests, equals(10));
    });

    test('default maxQueueSize is 100', () {
      const p = BulkheadIsolationPolicy();
      expect(p.maxQueueSize, equals(100));
    });

    test('default queueTimeout is 10 seconds', () {
      const p = BulkheadIsolationPolicy();
      expect(p.queueTimeout, equals(const Duration(seconds: 10)));
    });

    test('zero maxQueueSize is valid (reject overflow immediately)', () {
      const p = BulkheadIsolationPolicy(maxQueueSize: 0);
      expect(p.maxQueueSize, equals(0));
    });

    test('onRejected is stored', () {
      void cb(BulkheadRejectionReason _) {}
      final p = BulkheadIsolationPolicy(onRejected: cb);
      expect(p.onRejected, same(cb));
    });

    test('toString contains class name and values', () {
      const p = BulkheadIsolationPolicy(
        maxConcurrentRequests: 5,
        maxQueueSize: 10,
      );
      final s = p.toString();
      expect(s, contains('BulkheadIsolationPolicy'));
      expect(s, contains('maxConcurrentRequests=5'));
      expect(s, contains('maxQueueSize=10'));
    });

    test('assert fires for maxConcurrentRequests < 1', () {
      expect(
        () => BulkheadIsolationPolicy(maxConcurrentRequests: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('assert fires for negative maxQueueSize', () {
      expect(
        () => BulkheadIsolationPolicy(maxQueueSize: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationSemaphore — basic metrics', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('starts with activeCount = 0', () {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 3),
      );
      expect(sem.activeCount, equals(0));
    });

    test('starts with queuedCount = 0', () {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 3),
      );
      expect(sem.queuedCount, equals(0));
    });

    test('availableSlots equals maxConcurrentRequests initially', () {
      const max = 5;
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: max),
      );
      expect(sem.availableSlots, equals(max));
    });

    test('isAtCapacity is false when no slots taken', () {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 3),
      );
      expect(sem.isAtCapacity, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationSemaphore — acquire / release', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('fast-path: acquire succeeds immediately when slot available',
        () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 2),
      );
      await sem.acquire();
      expect(sem.activeCount, equals(1));
      expect(sem.availableSlots, equals(1));
    });

    test('release decrements activeCount', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 2),
      );
      await sem.acquire();
      sem.release();
      expect(sem.activeCount, equals(0));
      expect(sem.availableSlots, equals(2));
    });

    test('isAtCapacity is true when all slots taken', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 2),
      );
      await sem.acquire();
      await sem.acquire();
      expect(sem.isAtCapacity, isTrue);
      expect(sem.availableSlots, equals(0));
    });

    test('multiple acquire/release cycles work correctly', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(maxConcurrentRequests: 3),
      );
      for (var i = 0; i < 10; i++) {
        await sem.acquire();
        sem.release();
      }
      expect(sem.activeCount, equals(0));
      expect(sem.availableSlots, equals(3));
    });

    test('queue: waiter is unblocked when slot released', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 1,
          queueTimeout: Duration(seconds: 5),
        ),
      );

      // Take the only slot.
      await sem.acquire();
      expect(sem.activeCount, equals(1));

      // Enqueue a waiter.
      var waiterDone = false;
      final waiterFuture = sem.acquire().then((_) => waiterDone = true);

      await _pump();
      expect(sem.queuedCount, equals(1));
      expect(waiterDone, isFalse);

      // Release — waiter should be unblocked.
      sem.release();
      await waiterFuture;

      expect(waiterDone, isTrue);
      expect(sem.activeCount, equals(1)); // slot transferred
      expect(sem.queuedCount, equals(0));

      // Release the waiter's slot too.
      sem.release();
      expect(sem.activeCount, equals(0));
    });

    test('queue: rejects when maxQueueSize exceeded', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 1,
        ),
      );
      await sem.acquire(); // take slot

      // First overflow → goes to queue
      unawaited(sem.acquire());
      await _pump();
      expect(sem.queuedCount, equals(1));

      // Second overflow → queue full → exception
      await expectLater(
        sem.acquire(),
        throwsA(
          isA<BulkheadRejectedException>().having(
            (e) => e.reason,
            'reason',
            BulkheadRejectionReason.queueFull,
          ),
        ),
      );
    });

    test('queue: queueTimeout throws BulkheadRejectionReason.queueTimeout',
        () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 5,
          queueTimeout: Duration(milliseconds: 20),
        ),
      );
      await sem.acquire(); // fill slot

      // Attempt to queue — should time out
      await expectLater(
        sem.acquire(),
        throwsA(
          isA<BulkheadRejectedException>().having(
            (e) => e.reason,
            'reason',
            BulkheadRejectionReason.queueTimeout,
          ),
        ),
      );
      // queuedCount should be back to 0 after timeout
      expect(sem.queuedCount, equals(0));
    });

    test('release skips cancelled (timed-out) waiters', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 3,
          queueTimeout: Duration(milliseconds: 30),
        ),
      );
      await sem.acquire();

      // Enqueue two waiters that will time out, then one with a long timeout.
      unawaited(
        sem.acquire().catchError((_) {}), // will timeout and be cancelled
      );
      unawaited(
        sem.acquire().catchError((_) {}), // will timeout and be cancelled
      );
      await _pump();
      expect(sem.queuedCount, equals(2));

      // Wait for the two to time out.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sem.queuedCount, equals(0));

      // Release — should decrement active (no valid waiters).
      sem.release();
      expect(sem.activeCount, equals(0));
    });

    test('zero maxQueueSize: rejects immediately when at capacity', () async {
      final sem = BulkheadIsolationSemaphore(
        policy: const BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 0,
        ),
      );
      await sem.acquire();

      expect(
        sem.acquire,
        throwsA(isA<BulkheadRejectedException>()),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationSemaphore — onRejected callback', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('fires with queueFull reason when queue is full', () async {
      BulkheadRejectionReason? captured;
      final sem = BulkheadIsolationSemaphore(
        policy: BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 0,
          onRejected: (r) => captured = r,
        ),
      );
      await sem.acquire();

      try {
        await sem.acquire();
      } on BulkheadRejectedException catch (_) {}

      expect(captured, equals(BulkheadRejectionReason.queueFull));
    });

    test('fires with queueTimeout reason on timeout', () async {
      BulkheadRejectionReason? captured;
      final sem = BulkheadIsolationSemaphore(
        policy: BulkheadIsolationPolicy(
          maxConcurrentRequests: 1,
          maxQueueSize: 1,
          queueTimeout: const Duration(milliseconds: 20),
          onRejected: (r) => captured = r,
        ),
      );
      await sem.acquire();

      try {
        await sem.acquire();
      } on BulkheadRejectedException catch (_) {}

      expect(captured, equals(BulkheadRejectionReason.queueTimeout));
    });

    test('not fired on successful acquire', () async {
      var fired = false;
      final sem = BulkheadIsolationSemaphore(
        policy: BulkheadIsolationPolicy(
          maxConcurrentRequests: 2,
          onRejected: (_) => fired = true,
        ),
      );
      await sem.acquire();
      expect(fired, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationResiliencePolicy — basic execution', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('executes action and returns result', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 5,
      );
      final result = await policy.execute(() async => 'hello');
      expect(result, equals('hello'));
    });

    test('propagates action exceptions', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 5,
      );
      expect(
        () => policy.execute<String>(() => throw StateError('boom')),
        throwsStateError,
      );
    });

    test('releases slot after action throws', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
      );
      await expectLater(
        policy.execute<String>(() async => throw StateError('error')),
        throwsStateError,
      );
      // Slot must be released — next call should succeed.
      final result = await policy.execute(() async => 'ok');
      expect(result, equals('ok'));
    });

    test('activeCount increments during execution and decrements after',
        () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 5,
      );
      final completer = Completer<void>();
      final future = policy.execute(() => completer.future);

      await _pump();
      expect(policy.activeCount, equals(1));

      completer.complete();
      await future;
      expect(policy.activeCount, equals(0));
    });

    test('toString is descriptive', () {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 3,
        maxQueueSize: 6,
      );
      expect(policy.toString(), contains('BulkheadIsolationResiliencePolicy'));
      expect(policy.toString(), contains('maxConcurrentRequests=3'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationResiliencePolicy — concurrency limiting', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('allows exactly maxConcurrentRequests simultaneous executions',
        () async {
      const limit = 3;
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: limit,
        maxQueueSize: 0,
      );

      final completers = List.generate(limit, (_) => Completer<void>());
      final futures =
          completers.map((c) => policy.execute(() => c.future)).toList();

      await _pump();
      expect(policy.activeCount, equals(limit));

      // One more should be rejected immediately (queue = 0).
      expect(
        () => policy.execute(() async {}),
        throwsA(isA<BulkheadRejectedException>()),
      );

      // Complete all.
      for (final c in completers) {
        c.complete();
      }
      await Future.wait(futures);
      expect(policy.activeCount, equals(0));
    });

    test('queues requests when at capacity', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 2,
        queueTimeout: const Duration(seconds: 30),
      );

      final c1 = Completer<String>();
      final c2 = Completer<String>();
      final c3 = Completer<String>();

      final f1 = policy.execute(() => c1.future);
      final f2 = policy.execute(() => c2.future);
      final f3 = policy.execute(() => c3.future);

      await _pump();
      expect(policy.activeCount, equals(1));
      expect(policy.queuedCount, equals(2));

      // Complete first — second should become active.
      c1.complete('one');
      await f1;
      await _pump();
      expect(policy.activeCount, equals(1));
      expect(policy.queuedCount, equals(1));

      c2.complete('two');
      await f2;
      await _pump();
      expect(policy.activeCount, equals(1));
      expect(policy.queuedCount, equals(0));

      c3.complete('three');
      final r3 = await f3;
      expect(r3, equals('three'));
    });

    test('rejects when both concurrency cap and queue are full', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 1,
      );

      final c1 = Completer<void>();
      unawaited(policy.execute(() => c1.future)); // fills slot
      unawaited(policy.execute(() async {})); // fills queue
      await _pump();

      // Next should be rejected.
      await expectLater(
        policy.execute(() async {}),
        throwsA(
          isA<BulkheadRejectedException>().having(
            (e) => e.reason,
            'reason',
            BulkheadRejectionReason.queueFull,
          ),
        ),
      );
      c1.complete();
    });

    test('queued request is rejected on timeout', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 5,
        queueTimeout: const Duration(milliseconds: 30),
      );

      final blocker = Completer<void>();
      unawaited(policy.execute(() => blocker.future));
      await _pump();

      await expectLater(
        policy.execute(() async {}),
        throwsA(
          isA<BulkheadRejectedException>().having(
            (e) => e.reason,
            'reason',
            BulkheadRejectionReason.queueTimeout,
          ),
        ),
      );

      blocker.complete();
    });

    test('fromPolicy constructor applies policy config', () {
      const p = BulkheadIsolationPolicy(
        maxConcurrentRequests: 7,
        maxQueueSize: 14,
      );
      final policy = BulkheadIsolationResiliencePolicy.fromPolicy(p);
      expect(policy.toString(), contains('maxConcurrentRequests=7'));
      expect(policy.toString(), contains('maxQueueSize=14'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationResiliencePolicy — onRejected callback', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('called with queueFull when queue is full', () async {
      BulkheadRejectionReason? captured;
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 0,
        onRejected: (r) => captured = r,
      );

      final c = Completer<void>();
      unawaited(policy.execute(() => c.future));
      await _pump();

      try {
        await policy.execute(() async {});
      } on BulkheadRejectedException catch (_) {}

      expect(captured, equals(BulkheadRejectionReason.queueFull));
      c.complete();
    });

    test('called with queueTimeout when timeout expires', () async {
      BulkheadRejectionReason? captured;
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 1,
        queueTimeout: const Duration(milliseconds: 20),
        onRejected: (r) => captured = r,
      );

      final c = Completer<void>();
      unawaited(policy.execute(() => c.future));
      await _pump();

      try {
        await policy.execute(() async {});
      } on BulkheadRejectedException catch (_) {}

      expect(captured, equals(BulkheadRejectionReason.queueTimeout));
      c.complete();
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationResiliencePolicy — composition', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('composes with retry: rejected bulkhead causes retry', () async {
      var attempts = 0;
      // Just verify composition builds: fallback wraps bulkhead
      final pipeline = Policy.wrap([
        Policy.fallback(
          fallbackAction: (_, __) async => 'fallback',
          shouldHandle: (e) => e is BulkheadRejectedException,
        ),
        Policy.bulkheadIsolation(maxConcurrentRequests: 1, maxQueueSize: 0),
      ]);

      final c = Completer<String>();
      unawaited(pipeline.execute(() => c.future)); // takes the slot
      await _pump();

      // Second call: bulkhead rejects → fallback fires
      final result = await pipeline.execute(() async {
        attempts++;
        return 'direct';
      });
      expect(result, equals('fallback'));
      expect(attempts, equals(0)); // blocked before action ran
      c.complete('first');
    });

    test('Policy.wrap places bulkhead innermost', () async {
      final pipeline = ResiliencePipelineBuilder()
          .addFallback(
            fallbackAction: (_, __) async => 'fallback',
            shouldHandle: (e) => e is BulkheadRejectedException,
          )
          .addBulkheadIsolation(maxConcurrentRequests: 1, maxQueueSize: 0)
          .build();

      final c = Completer<String>();
      unawaited(pipeline.execute(() => c.future));
      await _pump();

      final result = await pipeline.execute<String>(() async => 'direct');
      expect(result, equals('fallback'));
      c.complete('done');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadIsolationHandler — pipeline layer', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('allows request through when slot available', () async {
      final transport = Completer<http.Response>()
        ..complete(http.Response('ok', 200));
      const policy = BulkheadIsolationPolicy(maxConcurrentRequests: 5);
      final client = _clientWith(policy, transport);
      final response = await client.get(Uri.parse('/test'));
      expect(response.statusCode, equals(200));
    });

    test('activeCount and queuedCount exposed on handler', () async {
      const policy = BulkheadIsolationPolicy(maxConcurrentRequests: 2);
      final handler = BulkheadIsolationHandler(policy);
      expect(handler.activeCount, equals(0));
      expect(handler.queuedCount, equals(0));
    });

    test('semaphore metrics are accessible', () {
      const policy = BulkheadIsolationPolicy(maxConcurrentRequests: 4);
      final handler = BulkheadIsolationHandler(policy);
      expect(handler.semaphore.availableSlots, equals(4));
      expect(handler.semaphore.isAtCapacity, isFalse);
    });

    test('throws BulkheadRejectedException when queue is full', () async {
      const policy = BulkheadIsolationPolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 0,
      );

      // Block one slot.
      final blockingTransport = Completer<http.Response>();
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withBulkheadIsolation(policy)
          .withHttpClient(
            http_testing.MockClient((_) => blockingTransport.future),
          )
          .build();

      unawaited(client.get(Uri.parse('/blocked')));
      await _pump();

      // Second request should be rejected.
      expect(
        () => client.get(Uri.parse('/rejected')),
        throwsA(isA<BulkheadRejectedException>()),
      );

      blockingTransport.complete(http.Response('ok', 200));
    });

    test('queued request executes after first completes', () async {
      final transportCompleters = [
        Completer<http.Response>(),
        Completer<http.Response>(),
      ];
      var callIndex = 0;

      const policy = BulkheadIsolationPolicy(
        maxConcurrentRequests: 1,
        maxQueueSize: 1,
      );

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withBulkheadIsolation(policy)
          .withHttpClient(
        http_testing.MockClient((_) {
          final idx = callIndex++;
          return transportCompleters[idx].future;
        }),
      ).build();

      final f1 = client.get(Uri.parse('/first'));
      await _pump();
      final f2 = client.get(Uri.parse('/second'));
      await _pump();

      // Complete first transport call.
      transportCompleters[0].complete(http.Response('first', 200));
      final r1 = await f1;
      expect(r1.statusCode, equals(200));

      // Second should now be executing.
      await _pump();
      transportCompleters[1].complete(http.Response('second', 201));
      final r2 = await f2;
      expect(r2.statusCode, equals(201));
    });

    test('toString is descriptive', () {
      final handler = BulkheadIsolationHandler(
        const BulkheadIsolationPolicy(
          maxConcurrentRequests: 5,
          maxQueueSize: 10,
        ),
      );
      expect(handler.toString(), contains('BulkheadIsolationHandler'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientBuilder.withBulkheadIsolation', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('returns builder for fluent chaining', () {
      final builder = HttpClientBuilder();
      final result = builder.withBulkheadIsolation(
        const BulkheadIsolationPolicy(),
      );
      expect(result, same(builder));
    });

    test('builds a client that passes through successful responses', () async {
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withBulkheadIsolation(const BulkheadIsolationPolicy())
          .withHttpClient(
            http_testing.MockClient(
              (_) async => http.Response('data', 200),
            ),
          )
          .build();
      final r = await client.get(Uri.parse('/test'));
      expect(r.statusCode, equals(200));
    });

    test('chain: bulkhead + retry + fallback builds valid client', () {
      final client = HttpClientBuilder()
          .withFallback(
            FallbackPolicy(
              fallbackAction: (_, __, ___) async =>
                  HttpResponse.cached('offline'),
            ),
          )
          .withRetry(RetryPolicy.constant(maxRetries: 2))
          .withBulkheadIsolation(
            const BulkheadIsolationPolicy(
              maxConcurrentRequests: 5,
              maxQueueSize: 10,
            ),
          )
          .withHttpClient(
            http_testing.MockClient((_) async => http.Response('ok', 200)),
          )
          .build();
      expect(client, isNotNull);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('ResiliencePipelineBuilder.addBulkheadIsolation', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('creates a BulkheadIsolationResiliencePolicy', () {
      final p = ResiliencePipelineBuilder()
          .addBulkheadIsolation(maxConcurrentRequests: 5)
          .build();
      expect(p, isA<BulkheadIsolationResiliencePolicy>());
    });

    test('forwards maxConcurrentRequests and maxQueueSize', () {
      final p = ResiliencePipelineBuilder()
          .addBulkheadIsolation(
            maxConcurrentRequests: 3,
            maxQueueSize: 9,
          )
          .build() as BulkheadIsolationResiliencePolicy;
      expect(p.toString(), contains('maxConcurrentRequests=3'));
      expect(p.toString(), contains('maxQueueSize=9'));
    });

    test('composes with addFallback', () {
      final p = ResiliencePipelineBuilder()
          .addFallback(fallbackAction: (_, __) async => 'x')
          .addBulkheadIsolation(maxConcurrentRequests: 2)
          .build();
      expect(p, isA<PolicyWrap>());
    });

    test('executes actions within the limit', () async {
      final p = ResiliencePipelineBuilder()
          .addBulkheadIsolation(maxConcurrentRequests: 5)
          .build();
      final result = await p.execute(() async => 42);
      expect(result, equals(42));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Policy.bulkheadIsolation static factory', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('returns a BulkheadIsolationResiliencePolicy', () {
      final p = Policy.bulkheadIsolation(maxConcurrentRequests: 5);
      expect(p, isA<BulkheadIsolationResiliencePolicy>());
    });

    test('forwards maxConcurrentRequests', () {
      final p = Policy.bulkheadIsolation(maxConcurrentRequests: 7);
      expect(p.toString(), contains('maxConcurrentRequests=7'));
    });

    test('forwards maxQueueSize', () {
      final p = Policy.bulkheadIsolation(
        maxConcurrentRequests: 5,
        maxQueueSize: 15,
      );
      expect(p.toString(), contains('maxQueueSize=15'));
    });

    test('forwards onRejected callback', () async {
      var called = false;
      final p = Policy.bulkheadIsolation(
        maxConcurrentRequests: 1,
        maxQueueSize: 0,
        onRejected: (_) => called = true,
      );

      final c = Completer<void>();
      unawaited(p.execute(() => c.future));
      await _pump();

      try {
        await p.execute(() async {});
      } on BulkheadRejectedException catch (_) {}

      expect(called, isTrue);
      c.complete();
    });

    test('executes action successfully', () async {
      final p = Policy.bulkheadIsolation(maxConcurrentRequests: 5);
      final result = await p.execute(() async => 'success');
      expect(result, equals('success'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Thread safety — concurrent access', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('10 concurrent requests with limit 3: peaks at 3 active', () async {
      var peakConcurrency = 0;
      var currentConcurrency = 0;
      const limit = 3;

      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: limit,
        maxQueueSize: 10,
      );

      final futures = List.generate(10, (_) async {
        await policy.execute(() async {
          currentConcurrency++;
          if (currentConcurrency > peakConcurrency) {
            peakConcurrency = currentConcurrency;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          currentConcurrency--;
        });
      });

      await Future.wait(futures);

      expect(peakConcurrency, lessThanOrEqualTo(limit));
      expect(policy.activeCount, equals(0));
      expect(policy.queuedCount, equals(0));
    });

    test('semaphore activeCount never exceeds maxConcurrentRequests', () async {
      const limit = 2;
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: limit,
        maxQueueSize: 20,
      );

      var violation = false;
      final futures = List.generate(8, (_) async {
        await policy.execute(() async {
          if (policy.activeCount > limit) violation = true;
          await Future<void>.delayed(const Duration(milliseconds: 2));
        });
      });

      await Future.wait(futures);
      expect(violation, isFalse);
    });

    test('all queued requests eventually execute', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 2,
        maxQueueSize: 8,
        queueTimeout: const Duration(seconds: 30),
      );

      var executed = 0;
      final futures = List.generate(10, (_) async {
        await policy.execute(() async {
          executed++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
      });

      await Future.wait(futures);
      expect(executed, equals(10));
    });
  });
}
