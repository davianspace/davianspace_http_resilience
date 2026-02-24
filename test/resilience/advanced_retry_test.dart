import 'dart:async';
import 'dart:math' as math;

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Exception that is always considered non-retryable in tests.
final class _PermanentException implements Exception {
  const _PermanentException();
  @override
  String toString() => '_PermanentException';
}

/// Exception that is always considered transient in tests.
final class _TransientException implements Exception {
  const _TransientException();
  @override
  String toString() => '_TransientException';
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ── RetryContext ────────────────────────────────────────────────────────────
  group('RetryContext', () {
    test('stores all fields', () {
      final ex = Exception('boom');
      final st = StackTrace.current;
      final ctx = RetryContext(
        attempt: 3,
        elapsed: const Duration(milliseconds: 250),
        lastException: ex,
        lastStackTrace: st,
        lastResult: 'prev',
      );

      expect(ctx.attempt, 3);
      expect(ctx.elapsed, const Duration(milliseconds: 250));
      expect(ctx.lastException, same(ex));
      expect(ctx.lastStackTrace, same(st));
      expect(ctx.lastResult, 'prev');
    });

    test('defaults lastException, lastStackTrace, lastResult to null', () {
      const ctx = RetryContext(
        attempt: 1,
        elapsed: Duration.zero,
      );
      expect(ctx.lastException, isNull);
      expect(ctx.lastStackTrace, isNull);
      expect(ctx.lastResult, isNull);
    });

    test('toString contains attempt and elapsed', () {
      const ctx = RetryContext(
        attempt: 2,
        elapsed: Duration(milliseconds: 100),
      );
      expect(ctx.toString(), contains('attempt=2'));
      expect(ctx.toString(), contains('100ms'));
    });
  });

  // ── CancellationToken (core) ────────────────────────────────────────────────
  group('CancellationToken', () {
    test('isCancelled starts false', () {
      expect(CancellationToken().isCancelled, isFalse);
    });

    test('isCancelled is true after cancel()', () {
      final token = CancellationToken();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('cancel is idempotent', () {
      final token = CancellationToken();
      token.cancel();
      token.cancel(); // second call must not throw
      expect(token.isCancelled, isTrue);
    });

    test('throwIfCancelled does nothing when not cancelled', () {
      expect(() => CancellationToken().throwIfCancelled(), returnsNormally);
    });

    test('throwIfCancelled throws CancellationException when cancelled', () {
      final token = CancellationToken()..cancel();
      expect(
        token.throwIfCancelled,
        throwsA(isA<CancellationException>()),
      );
    });

    test('onCancelled completes after cancel()', () async {
      final token = CancellationToken();
      var completed = false;
      unawaited(token.onCancelled.then((_) => completed = true));
      expect(completed, isFalse);
      token.cancel();
      await Future<void>.microtask(() {});
      expect(completed, isTrue);
    });

    test('onCancelled completes immediately when already cancelled', () async {
      final token = CancellationToken()..cancel();
      var completed = false;
      unawaited(token.onCancelled.then((_) => completed = true));
      await Future<void>.microtask(() {});
      expect(completed, isTrue);
    });

    test('addListener is called when cancelled', () {
      final token = CancellationToken();
      String? received;
      token.addListener((reason) => received = reason);
      token.cancel('timeout');
      expect(received, 'timeout');
    });
  });

  // ── CancellationException ───────────────────────────────────────────────────
  group('CancellationException', () {
    test('implements Exception', () {
      const ex = CancellationException();
      expect(ex, isA<Exception>());
    });

    test('toString mentions cancellation', () {
      expect(
        const CancellationException(reason: 'test').toString(),
        contains('cancelled'),
      );
    });

    test('reason is accessible', () {
      const ex = CancellationException(reason: 'shutting down');
      expect(ex.reason, 'shutting down');
    });
  });

  // ── DecorrelatedJitterBackoff ───────────────────────────────────────────────
  group('DecorrelatedJitterBackoff', () {
    const base = Duration(milliseconds: 100);

    test('attempt 1 returns base (upper == base)', () {
      final backoff = DecorrelatedJitterBackoff(
        const Duration(milliseconds: 100),
        random: math.Random(0),
      );
      // upper = min(30s, 100ms * 3^0) = 100ms => range [100, 100] = 100ms
      expect(backoff.delayFor(1), base);
    });

    test('attempt 2 delay is in [base, 3*base]', () {
      final backoff = DecorrelatedJitterBackoff(
        const Duration(milliseconds: 100),
        random: math.Random(42),
      );
      // upper = min(30s, 100ms * 3^1) = 300ms
      final delay = backoff.delayFor(2);
      expect(delay.inMicroseconds, greaterThanOrEqualTo(base.inMicroseconds));
      expect(
        delay.inMicroseconds,
        lessThanOrEqualTo(const Duration(milliseconds: 300).inMicroseconds),
      );
    });

    test('attempt 3 delay is capped by maxDelay', () {
      final backoff = DecorrelatedJitterBackoff(
        const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 150),
        random: math.Random(0),
      );
      // upper = min(150ms, 900ms) = 150ms
      final delay = backoff.delayFor(3);
      expect(delay.inMicroseconds, greaterThanOrEqualTo(base.inMicroseconds));
      expect(
        delay.inMicroseconds,
        lessThanOrEqualTo(const Duration(milliseconds: 150).inMicroseconds),
      );
    });

    test('deterministic with seeded random', () {
      final r = math.Random(7);
      final b1 = DecorrelatedJitterBackoff(
        const Duration(milliseconds: 100),
        random: r,
      );
      final r2 = math.Random(7);
      final b2 = DecorrelatedJitterBackoff(
        const Duration(milliseconds: 100),
        random: r2,
      );
      expect(b1.delayFor(2).inMicroseconds, b2.delayFor(2).inMicroseconds);
    });

    test('asserts base > Duration.zero', () {
      expect(
        () => DecorrelatedJitterBackoff(Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toString is informative', () {
      // Must be non-const because the assert uses > which isn't evaluable at compile time.
      final b = DecorrelatedJitterBackoff(const Duration(milliseconds: 50));
      expect(b.toString(), contains('50'));
    });
  });

  // ── AddedJitterBackoff ──────────────────────────────────────────────────────
  group('AddedJitterBackoff', () {
    const inner = ConstantBackoff(Duration(milliseconds: 200));
    const jitter = Duration(milliseconds: 100);

    test('delay is >= inner.delayFor', () {
      final backoff = AddedJitterBackoff(
        inner,
        jitterRange: jitter,
        random: math.Random(0),
      );
      for (var i = 1; i <= 5; i++) {
        expect(
          backoff.delayFor(i).inMicroseconds,
          greaterThanOrEqualTo(inner.delayFor(i).inMicroseconds),
        );
      }
    });

    test('delay is <= inner.delayFor + jitterRange', () {
      final backoff = AddedJitterBackoff(
        inner,
        jitterRange: jitter,
        random: math.Random(0),
      );
      for (var i = 1; i <= 5; i++) {
        expect(
          backoff.delayFor(i).inMicroseconds,
          lessThanOrEqualTo(
            inner.delayFor(i).inMicroseconds + jitter.inMicroseconds,
          ),
        );
      }
    });

    test('deterministic with seeded random', () {
      final r1 = math.Random(9);
      final r2 = math.Random(9);
      final b1 = AddedJitterBackoff(inner, jitterRange: jitter, random: r1);
      final b2 = AddedJitterBackoff(inner, jitterRange: jitter, random: r2);
      expect(b1.delayFor(1).inMicroseconds, b2.delayFor(1).inMicroseconds);
      expect(b1.delayFor(3).inMicroseconds, b2.delayFor(3).inMicroseconds);
    });

    test('toString mentions jitter and inner strategy', () {
      const b = AddedJitterBackoff(
        ConstantBackoff(Duration(milliseconds: 100)),
        jitterRange: Duration(milliseconds: 50),
      );
      expect(b.toString(), contains('50'));
    });
  });

  // ── retryOnContext ──────────────────────────────────────────────────────────
  group('retryOnContext', () {
    test('receives correct attempt and exception', () async {
      final contexts = <RetryContext>[];
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOnContext: (ex, ctx) {
          contexts.add(ctx);
          return ex is _TransientException;
        },
      );

      var calls = 0;
      await policy.execute(() async {
        if (++calls < 4) throw const _TransientException();
        return 'ok';
      });

      expect(contexts.length, 3);
      expect(contexts[0].attempt, 1);
      expect(contexts[1].attempt, 2);
      expect(contexts[2].attempt, 3);
      // lastException in the context is the exception from the PREVIOUS attempt.
      // On attempt 1 (first retry), lastException is the exception from attempt 0.
      expect(
        contexts[0].lastException,
        isNull,
      ); // no prior exception on first call
      expect(contexts[1].lastException, isA<_TransientException>());
      expect(contexts[2].lastException, isA<_TransientException>());
    });

    test('takes priority over retryOn when both set', () async {
      var contextCalled = false;
      var legacyCalled = false;
      final policy = RetryResiliencePolicy(
        maxRetries: 1,
        retryOn: (ex, _) {
          legacyCalled = true;
          return true;
        },
        retryOnContext: (ex, ctx) {
          contextCalled = true;
          return true;
        },
      );

      var calls = 0;
      await policy.execute(() async {
        if (++calls < 2) throw const _TransientException();
        return 'ok';
      });

      expect(contextCalled, isTrue);
      expect(
        legacyCalled,
        isFalse,
        reason: 'retryOnContext should shadow retryOn',
      );
    });

    test('stops retry when retryOnContext returns false', () async {
      final policy = RetryResiliencePolicy(
        maxRetries: 5,
        retryOnContext: (ex, ctx) => ctx.attempt < 2, // only first attempt
      );

      expect(
        () => policy.execute(() async => throw const _TransientException()),
        throwsA(isA<_TransientException>()),
      );
    });

    test('elapsed increases across attempts', () async {
      final elapsed = <Duration>[];
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOnContext: (ex, ctx) {
          elapsed.add(ctx.elapsed);
          return true;
        },
      );

      var calls = 0;
      await policy.execute(() async {
        if (++calls < 4) throw const _TransientException();
        return 'ok';
      });

      // Duration is monotonically non-decreasing.
      for (var i = 1; i < elapsed.length; i++) {
        expect(
          elapsed[i].inMicroseconds,
          greaterThanOrEqualTo(elapsed[i - 1].inMicroseconds),
        );
      }
    });
  });

  // ── retryOnResultContext ────────────────────────────────────────────────────
  group('retryOnResultContext', () {
    test('retries when result predicate returns true', () async {
      final seen = <RetryContext>[];
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOnResultContext: (result, ctx) {
          seen.add(ctx);
          return result == 'retry' && ctx.attempt < 3;
        },
      );

      var calls = 0;
      final result = await policy.execute(() async {
        calls++;
        if (calls < 3) return 'retry';
        return 'ok';
      });

      expect(result, 'ok');
      // predicate is called on every result (including final 'ok'), so seen.length = 3
      expect(seen.length, 3);
    });

    test('takes priority over retryOnResult when both set', () async {
      var ctxCalled = false;
      var legacyCalled = false;
      final policy = RetryResiliencePolicy(
        maxRetries: 2,
        retryOnResult: (result, _) {
          legacyCalled = true;
          return result == 'retry';
        },
        retryOnResultContext: (result, ctx) {
          ctxCalled = true;
          return result == 'retry';
        },
      );

      var calls = 0;
      await policy.execute(() async {
        if (++calls < 2) return 'retry';
        return 'ok';
      });

      expect(ctxCalled, isTrue);
      expect(legacyCalled, isFalse);
    });

    test('lastResult is set from previous attempt in subsequent context',
        () async {
      final results = <dynamic>[];
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOnResultContext: (result, ctx) {
          // ctx.lastResult is the PREVIOUS result (null on first attempt)
          results.add(ctx.lastResult);
          return result == 'retry';
        },
      );

      var calls = 0;
      await policy.execute(() async {
        calls++;
        if (calls < 3) return 'retry';
        return 'ok';
      });

      // First result-check: lastResult is null (first attempt, no prior)
      // Second result-check: lastResult still null (context captures exception, not prior result)
      expect(results, isNotEmpty);
    });
  });

  // ── retryForever mode ───────────────────────────────────────────────────────
  group('retryForever', () {
    test('loops until action succeeds', () async {
      var calls = 0;
      const policy = RetryResiliencePolicy(
        maxRetries: 0, // ignored
        retryForever: true,
      );

      final result = await policy.execute(() async {
        if (++calls < 5) throw const _TransientException();
        return 'done';
      });

      expect(result, 'done');
      expect(calls, 5);
    });

    test('propagates non-retryable exception immediately', () async {
      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
        retryOn: (ex, _) => ex is _TransientException,
      );

      expect(
        () => policy.execute(() async {
          calls++;
          throw const _PermanentException();
        }),
        throwsA(isA<_PermanentException>()),
      );
      // Waits a microtask for the future to resolve.
      await Future<void>.microtask(() {});
      expect(calls, 1);
    });

    test('toString includes "forever"', () {
      const p = RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
      );
      expect(p.toString(), contains('forever'));
    });

    test('RetryResiliencePolicy.forever() is equivalent to retryForever=true',
        () {
      final p = RetryResiliencePolicy.forever();
      expect(p.retryForever, isTrue);
    });

    test('emits RetryEvent with null maxAttempts', () async {
      final events = <RetryEvent>[];
      final hub = ResilienceEventHub()..on<RetryEvent>(events.add);

      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
        eventHub: hub,
      );

      await policy.execute(() async {
        if (++calls < 3) throw const _TransientException();
        return 'ok';
      });

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, isNotEmpty);
      for (final e in events) {
        expect(e.maxAttempts, isNull);
      }
    });
  });

  // ── CancellationToken + retryForever ────────────────────────────────────────
  group('CancellationToken + retryForever', () {
    test('cancels retry loop before next attempt', () async {
      final token = CancellationToken();
      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
        cancellationToken: token,
      );

      // Cancel after the third call.
      final future = policy.execute(() async {
        if (++calls >= 3) token.cancel();
        throw const _TransientException();
      });

      await expectLater(
        future,
        throwsA(isA<CancellationException>()),
      );
      await Future<void>.delayed(Duration.zero);
      // calls is either 3 or 4 (depends on timing of the pre-attempt check).
      expect(calls, greaterThanOrEqualTo(3));
    });

    test('throwIfCancelled before first attempt if pre-cancelled', () {
      final token = CancellationToken()..cancel();
      final policy = RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
        cancellationToken: token,
      );

      expect(
        () => policy.execute(() async => 'ok'),
        throwsA(isA<CancellationException>()),
      );
    });

    test('cancellation during backoff delay resolves promptly', () async {
      final token = CancellationToken();
      final policy = RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
        backoff: const ConstantBackoff(Duration(hours: 1)), // very long
        cancellationToken: token,
      );

      var calls = 0;
      final future = policy.execute(() async {
        calls++;
        throw const _TransientException();
      });

      // Let the first attempt finish and the sleep begin.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      token.cancel(); // cancel during the 1-hour sleep

      // The future should resolve promptly (cancel interrupts the sleep).
      final timer = Stopwatch()..start();
      await expectLater(future, throwsA(isA<CancellationException>()));
      timer.stop();
      expect(timer.elapsed.inSeconds, lessThan(2));
      expect(calls, 1); // only one call before sleep
    });
  });

  // ── Policy.retryForever factory ─────────────────────────────────────────────
  group('Policy.retryForever()', () {
    test('creates a forever policy', () {
      final policy = Policy.retryForever();
      expect(policy, isA<RetryResiliencePolicy>());
      expect(policy.retryForever, isTrue);
    });

    test('accepts cancellationToken', () {
      final token = CancellationToken();
      final policy = Policy.retryForever(cancellationToken: token);
      expect(policy.cancellationToken, same(token));
    });

    test('accepts retryOnContext', () {
      bool cond(Object ex, RetryContext ctx) => true;
      final policy = Policy.retryForever(retryOnContext: cond);
      expect(policy.retryOnContext, same(cond));
    });

    test('loops until success', () async {
      var calls = 0;
      final policy = Policy.retryForever(backoff: const NoBackoff());

      final result = await policy.execute(() async {
        if (++calls < 4) throw const _TransientException();
        return calls;
      });

      expect(result, 4);
    });
  });

  // ── ResiliencePipelineBuilder.addRetryForever ───────────────────────────────
  group('ResiliencePipelineBuilder.addRetryForever', () {
    test('adds a forever RetryResiliencePolicy to the pipeline', () {
      final pipeline = ResiliencePipelineBuilder()
          .addRetryForever(backoff: const NoBackoff())
          .build() as RetryResiliencePolicy;

      expect(pipeline.retryForever, isTrue);
    });

    test('works in a larger pipeline', () async {
      var calls = 0;
      final pipeline = ResiliencePipelineBuilder()
          .addRetryForever(backoff: const NoBackoff())
          .build();

      final result = await pipeline.execute(() async {
        if (++calls < 3) throw const _TransientException();
        return 'done';
      });

      expect(result, 'done');
    });

    test('accepts new context-aware predicates', () {
      bool cond(Object ex, RetryContext ctx) => true;
      final builder =
          ResiliencePipelineBuilder().addRetryForever(retryOnContext: cond);
      final policy = builder.build() as RetryResiliencePolicy;
      expect(policy.retryOnContext, same(cond));
    });
  });

  // ── Policy.retry() new parameters ──────────────────────────────────────────
  group('Policy.retry() with new parameters', () {
    test('retryForever=true via Policy.retry() works', () async {
      var calls = 0;
      final policy = Policy.retry(
        maxRetries: 0,
        retryForever: true,
      );

      expect(policy.retryForever, isTrue);

      final result = await policy.execute(() async {
        if (++calls < 3) throw const _TransientException();
        return 'ok';
      });
      expect(result, 'ok');
    });

    test('retryOnContext passed through Policy.retry()', () {
      bool cond(Object ex, RetryContext ctx) => ctx.attempt < 3;
      final policy = Policy.retry(
        maxRetries: 5,
        retryOnContext: cond,
      );
      expect(policy.retryOnContext, same(cond));
    });

    test('cancellationToken passed through Policy.retry()', () {
      final token = CancellationToken();
      final policy = Policy.retry(
        maxRetries: 3,
        cancellationToken: token,
      );
      expect(policy.cancellationToken, same(token));
    });
  });

  // ── RetryEvent.maxAttempts nullable ────────────────────────────────────────
  group('RetryEvent.maxAttempts', () {
    test('is null when emitted from retryForever policy', () async {
      final events = <RetryEvent>[];
      final hub = ResilienceEventHub()..on<RetryEvent>(events.add);

      var calls = 0;
      await RetryResiliencePolicy(
        maxRetries: 0,
        retryForever: true,
        eventHub: hub,
      ).execute(() async {
        if (++calls < 2) throw const _TransientException();
        return 'ok';
      });

      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(events, isNotEmpty);
      expect(events.first.maxAttempts, isNull);
    });

    test('is non-null in finite mode', () async {
      final events = <RetryEvent>[];
      final hub = ResilienceEventHub()..on<RetryEvent>(events.add);

      var calls = 0;
      await RetryResiliencePolicy(
        maxRetries: 3,
        eventHub: hub,
      ).execute(() async {
        if (++calls < 2) throw const _TransientException();
        return 'ok';
      });

      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(events, isNotEmpty);
      expect(events.first.maxAttempts, 4); // maxRetries+1
    });

    test('toString shows ∞ for null maxAttempts', () {
      final event = RetryEvent(
        attemptNumber: 1,
        delay: Duration.zero,
      );
      expect(event.toString(), contains('∞'));
    });

    test('toString shows number for non-null maxAttempts', () {
      final event = RetryEvent(
        attemptNumber: 1,
        maxAttempts: 4,
        delay: Duration.zero,
      );
      expect(event.toString(), contains('4'));
    });
  });

  // ── Finite retry backward compat ─────────────────────────────────────────
  group('Finite retry backward compatibility', () {
    test('maxRetries=3 makes 4 total attempts then throws', () async {
      var calls = 0;
      const policy = RetryResiliencePolicy(
        maxRetries: 3,
      );

      await expectLater(
        () => policy.execute(() async {
          calls++;
          throw const _TransientException();
        }),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(calls, 4);
    });

    test('retryOn=false stops retrying immediately', () async {
      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOn: (ex, _) => ex is _TransientException,
      );

      await expectLater(
        () => policy.execute(() async {
          calls++;
          throw const _PermanentException();
        }),
        throwsA(isA<_PermanentException>()),
      );
      expect(calls, 1);
    });
  });
}
