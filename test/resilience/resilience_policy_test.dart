import 'dart:async';
import 'dart:math' as math;

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test helpers
// ════════════════════════════════════════════════════════════════════════════

/// An exception with a predictable runtimeType string (unlike `Exception()`).
final class _AppException implements Exception {
  const _AppException([this.message = '']);
  final String message;
  @override
  String toString() => '_AppException($message)';
}

final class _TransientException implements Exception {
  const _TransientException();
}

final class _PermanentException implements Exception {
  const _PermanentException();
}

/// A [ResiliencePolicy] that records entry/exit events for order verification.
final class _LoggingPolicy extends ResiliencePolicy {
  _LoggingPolicy(this.name, this.log);
  final String name;
  final List<String> log;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    log.add('$name:before');
    final result = await action();
    log.add('$name:after');
    return result;
  }

  @override
  String toString() => '_LoggingPolicy($name)';
}

/// A [ResiliencePolicy] that records its name whenever an exception propagates
/// through it (but always re-throws).
final class _CatchingPolicy extends ResiliencePolicy {
  _CatchingPolicy(this.name, this.seenBy);
  final String name;
  final List<String> seenBy;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (_) {
      seenBy.add(name);
      rethrow;
    }
  }
}

/// A [ResiliencePolicy] that intercepts exceptions and swallows them,
/// calling [onError] but returning `null` (cast to `T`).
final class _InterceptPolicy extends ResiliencePolicy {
  _InterceptPolicy({required this.onError});
  final void Function(Object) onError;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on Object catch (e) {
      onError(e);
      return null as T;
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Backoff strategy tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('RetryBackoff strategies', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('NoBackoff always returns Duration.zero', () {
      const b = NoBackoff();
      for (var i = 1; i <= 5; i++) {
        expect(b.delayFor(i), Duration.zero);
      }
    });

    test('ConstantBackoff returns the same delay for every attempt', () {
      const b = ConstantBackoff(Duration(milliseconds: 500));
      expect(b.delayFor(1), const Duration(milliseconds: 500));
      expect(b.delayFor(3), const Duration(milliseconds: 500));
      expect(b.delayFor(10), const Duration(milliseconds: 500));
    });

    test('LinearBackoff returns base × attempt', () {
      const b = LinearBackoff(Duration(milliseconds: 100));
      expect(b.delayFor(1), const Duration(milliseconds: 100));
      expect(b.delayFor(2), const Duration(milliseconds: 200));
      expect(b.delayFor(5), const Duration(milliseconds: 500));
    });

    test('ExponentialBackoff doubles each attempt', () {
      const b = ExponentialBackoff(Duration(milliseconds: 100));
      expect(b.delayFor(1), const Duration(milliseconds: 100)); // 100*2^0
      expect(b.delayFor(2), const Duration(milliseconds: 200)); // 100*2^1
      expect(b.delayFor(3), const Duration(milliseconds: 400)); // 100*2^2
      expect(b.delayFor(4), const Duration(milliseconds: 800)); // 100*2^3
    });

    test('ExponentialBackoff respects maxDelay ceiling', () {
      const b = ExponentialBackoff(
        Duration(milliseconds: 200),
        maxDelay: Duration(milliseconds: 500),
      );
      expect(b.delayFor(1), const Duration(milliseconds: 200));
      expect(b.delayFor(2), const Duration(milliseconds: 400));
      expect(b.delayFor(3), const Duration(milliseconds: 500)); // capped
      expect(b.delayFor(10), const Duration(milliseconds: 500)); // capped
    });

    test('ExponentialBackoff with jitter stays within [0, cappedDelay]', () {
      final rng = math.Random(42);
      final b = ExponentialBackoff(
        const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 5),
        useJitter: true,
        random: rng,
      );
      for (var i = 1; i <= 10; i++) {
        final d = b.delayFor(i);
        // Full-jitter: must be in [0, cappedDelay]
        final cap = (100 * math.pow(2, i - 1)).round().clamp(0, 5000);
        expect(d.inMilliseconds, inInclusiveRange(0, cap));
      }
    });

    test('JitteredBackoff applies jitter on top of inner strategy', () {
      final rng = math.Random(1);
      final b = JitteredBackoff(
        const LinearBackoff(Duration(milliseconds: 100)),
        random: rng,
      );
      for (var i = 1; i <= 5; i++) {
        final d = b.delayFor(i);
        // Must be in [0, linear_delay] i.e. [0, 100*i]
        expect(d.inMilliseconds, inInclusiveRange(0, 100 * i));
      }
    });

    test('CappedBackoff clamps underlying strategy', () {
      const b = CappedBackoff(
        LinearBackoff(Duration(milliseconds: 100)),
        Duration(milliseconds: 250),
      );
      expect(b.delayFor(1), const Duration(milliseconds: 100));
      expect(b.delayFor(2), const Duration(milliseconds: 200));
      expect(b.delayFor(3), const Duration(milliseconds: 250)); // capped
      expect(b.delayFor(5), const Duration(milliseconds: 250)); // capped
    });

    test('CustomBackoff delegates to the provided function', () {
      final b = CustomBackoff((n) => Duration(seconds: n * n));
      expect(b.delayFor(1), const Duration(seconds: 1));
      expect(b.delayFor(3), const Duration(seconds: 9));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryResiliencePolicy — retry count', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('succeeds on the first attempt when action does not throw', () async {
      const policy = RetryResiliencePolicy(maxRetries: 3);
      var calls = 0;
      final result = await policy.execute(() async {
        calls++;
        return 42;
      });
      expect(result, 42);
      expect(calls, 1);
    });

    test('retries up to maxRetries times on exception', () async {
      const policy = RetryResiliencePolicy(maxRetries: 3);
      var calls = 0;
      await expectLater(
        policy.execute<int>(() async {
          calls++;
          throw const _AppException('fail');
        }),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(calls, 4); // 1 initial + 3 retries
    });

    test('RetryExhaustedException.attemptsMade equals maxRetries + 1',
        () async {
      const policy = RetryResiliencePolicy(maxRetries: 2);
      late RetryExhaustedException caught;
      try {
        await policy.execute<void>(
          () async => throw const _AppException(),
        );
      } on RetryExhaustedException catch (e) {
        caught = e;
      }
      expect(caught.attemptsMade, 3);
    });

    test('succeeds on nth attempt when action eventually stops throwing',
        () async {
      var attempts = 0;
      const policy = RetryResiliencePolicy(maxRetries: 4);
      final result = await policy.execute(() async {
        attempts++;
        if (attempts < 3) throw const _AppException('not yet');
        return 'done';
      });
      expect(result, 'done');
      expect(attempts, 3);
    });

    test('maxRetries = 0 means exactly one attempt', () async {
      const policy = RetryResiliencePolicy(maxRetries: 0);
      var calls = 0;
      await expectLater(
        policy.execute<void>(() async {
          calls++;
          throw const _AppException();
        }),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(calls, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryResiliencePolicy — exception filtering', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('retryOn predicate returning false propagates exception immediately',
        () async {
      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 5,
        retryOn: (ex, _) => ex is _TransientException,
      );
      await expectLater(
        policy.execute<void>(() async {
          calls++;
          throw const _PermanentException();
        }),
        throwsA(isA<_PermanentException>()),
      );
      expect(calls, 1); // not retried
    });

    test('only retries for matching exception type, stops on non-match',
        () async {
      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 5,
        retryOn: (ex, _) => ex is _TransientException,
      );
      await expectLater(
        policy.execute<void>(() async {
          calls++;
          if (calls < 3) throw const _TransientException();
          throw const _PermanentException(); // non-retryable
        }),
        throwsA(isA<_PermanentException>()),
      );
      expect(calls, 3);
    });

    test('retryOn receives correct 1-based attempt number', () async {
      final attemptNumbers = <int>[];
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOn: (_, attempt) {
          attemptNumbers.add(attempt);
          return true;
        },
      );
      await expectLater(
        policy.execute<void>(() async => throw const _AppException()),
        throwsA(isA<RetryExhaustedException>()),
      );
      // retryOn is called on every failed attempt — including the last — so
      // that non-retryable exceptions are still propagated immediately.
      expect(attemptNumbers, [1, 2, 3, 4]);
    });

    test('original exception is preserved in RetryExhaustedException.cause',
        () async {
      const original = _AppException('root cause');
      const policy = RetryResiliencePolicy(maxRetries: 1);
      late RetryExhaustedException caught;
      try {
        await policy.execute<void>(() async => throw original);
      } on RetryExhaustedException catch (e) {
        caught = e;
      }
      expect(caught.cause, same(original));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryResiliencePolicy — result-based retry', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('retryOnResult triggers retry when predicate returns true', () async {
      var calls = 0;
      final policy = RetryResiliencePolicy(
        maxRetries: 3,
        retryOnResult: (result, _) => result == 'bad',
      );
      final result = await policy.execute(() async {
        calls++;
        return calls < 3 ? 'bad' : 'good';
      });
      expect(result, 'good');
      expect(calls, 3);
    });

    test('result is returned on last attempt even if retryOnResult is true',
        () async {
      final policy = RetryResiliencePolicy(
        maxRetries: 2,
        retryOnResult: (_, __) => true, // always wants to retry
      );
      var calls = 0;
      final result = await policy.execute(() async {
        calls++;
        return 'value';
      });
      // Last attempt returns regardless
      expect(result, 'value');
      expect(calls, 3); // 1 + 2 retries
    });

    test('forHttp factory retries on matching status codes', () async {
      var calls = 0;
      final policy = RetryResiliencePolicy.forHttp(
        maxRetries: 2,
        retryOnStatusCodes: [503],
        backoff: const NoBackoff(),
      );
      final response = await policy.execute(() async {
        calls++;
        return calls < 3
            ? const HttpResponse(statusCode: 503)
            : HttpResponse.ok();
      });
      expect(response.statusCode, 200);
      expect(calls, 3);
    });

    test('forHttp does not retry on non-listed status codes', () async {
      var calls = 0;
      final policy = RetryResiliencePolicy.forHttp(
        maxRetries: 3,
        retryOnStatusCodes: [503],
        backoff: const NoBackoff(),
      );
      final response = await policy.execute(() async {
        calls++;
        return const HttpResponse(statusCode: 400); // not in list
      });
      expect(response.statusCode, 400);
      expect(calls, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryResiliencePolicy — backoff timing', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('ConstantBackoff delays are applied between retries', () {
      fakeAsync((fake) {
        var calls = 0;
        const policy = RetryResiliencePolicy(
          maxRetries: 3,
          backoff: ConstantBackoff(Duration(seconds: 1)),
        );

        Object? caught;
        policy.execute<void>(() async {
          calls++;
          throw const _AppException();
        }).catchError((Object e) {
          caught = e;
        });

        // Before any delay: only 1 call (the initial attempt).
        fake.flushMicrotasks();
        expect(calls, 1);

        // After 1s: 2nd attempt fires, then waits another 1s.
        fake.elapse(const Duration(seconds: 1));
        expect(calls, 2);

        fake.elapse(const Duration(seconds: 1));
        expect(calls, 3);

        fake.elapse(const Duration(seconds: 1));
        expect(calls, 4);

        fake.flushMicrotasks();
        expect(caught, isA<RetryExhaustedException>());
      });
    });

    test('ExponentialBackoff delays double with each retry', () {
      fakeAsync((fake) {
        var calls = 0;
        const policy = RetryResiliencePolicy(
          maxRetries: 3,
          backoff: ExponentialBackoff(Duration(milliseconds: 100)),
        );

        policy.execute<void>(() async {
          calls++;
          throw const _AppException();
        }).ignore();

        // attempt 1 fires immediately
        fake.flushMicrotasks();
        expect(calls, 1);

        // 100ms → attempt 2
        fake.elapse(const Duration(milliseconds: 100));
        expect(calls, 2);

        // 200ms → attempt 3
        fake.elapse(const Duration(milliseconds: 200));
        expect(calls, 3);

        // 400ms → attempt 4 (last)
        fake.elapse(const Duration(milliseconds: 400));
        expect(calls, 4);
      });
    });

    test('LinearBackoff delays increase linearly with each retry', () {
      fakeAsync((fake) {
        var calls = 0;
        const policy = RetryResiliencePolicy(
          maxRetries: 3,
          backoff: LinearBackoff(Duration(milliseconds: 100)),
        );

        policy.execute<void>(() async {
          calls++;
          throw const _AppException();
        }).ignore();

        fake.flushMicrotasks();
        expect(calls, 1); // attempt 1

        fake.elapse(
          const Duration(milliseconds: 100),
        ); // +100 ms (attempt 1 delay)
        expect(calls, 2); // attempt 2

        fake.elapse(
          const Duration(milliseconds: 200),
        ); // +200 ms (attempt 2 delay)
        expect(calls, 3); // attempt 3

        fake.elapse(
          const Duration(milliseconds: 300),
        ); // +300 ms (attempt 3 delay)
        expect(calls, 4); // attempt 4
      });
    });

    test('NoBackoff fires all retries without any time elapsing', () async {
      var calls = 0;
      const policy = RetryResiliencePolicy(maxRetries: 5);
      await expectLater(
        policy.execute<void>(() async {
          calls++;
          throw const _AppException();
        }),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(calls, 6);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryResiliencePolicy — Policy.retry factory', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('Policy.retry produces a RetryResiliencePolicy', () {
      final p = Policy.retry(maxRetries: 2);
      expect(p, isA<RetryResiliencePolicy>());
      expect(p.maxRetries, 2);
    });

    test('Policy.httpRetry produces HTTP-aware policy', () async {
      var calls = 0;
      final p = Policy.httpRetry(
        maxRetries: 2,
        backoff: const NoBackoff(),
        retryOnStatusCodes: [500],
      );
      final response = await p.execute(() async {
        calls++;
        return calls < 3
            ? const HttpResponse(statusCode: 500)
            : HttpResponse.ok();
      });
      expect(response.isSuccess, isTrue);
      expect(calls, 3);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('CircuitBreakerResiliencePolicy', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('closed circuit passes requests through', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-pass',
        registry: registry,
      );
      final result = await policy.execute(() async => 'ok');
      expect(result, 'ok');
    });

    test('circuit opens after failureThreshold consecutive failures', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-open',
        failureThreshold: 2,
        registry: registry,
      );

      // Two failures open the circuit.
      for (var i = 0; i < 2; i++) {
        try {
          await policy.execute<void>(() async => throw const _AppException());
        } on _AppException {
          // expected
        }
      }

      expect(policy.circuitState, CircuitState.open);
    });

    test('open circuit rejects immediately with CircuitOpenException',
        () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-reject',
        failureThreshold: 1,
        registry: registry,
      );

      // Trip the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on _AppException {
        // expected
      }

      // Next call is rejected.
      await expectLater(
        policy.execute(() async => 'should not reach'),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    test('circuit closes again after recovery', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-recover',
        failureThreshold: 1,
        breakDuration: Duration.zero, // immediate half-open
        registry: registry,
      );

      // Trip the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on _AppException {
        // expected
      }
      // With breakDuration: Duration.zero the break window expires immediately,
      // so circuitState returns halfOpen as soon as the getter is called.
      expect(policy.circuitState, CircuitState.halfOpen);

      // Successful probe closes the circuit.
      await policy.execute(() async => 'probe');
      expect(policy.circuitState, CircuitState.closed);
    });

    test('Policy.circuitBreaker factory produces correct policy', () {
      final p = Policy.circuitBreaker(circuitName: 'test', failureThreshold: 3);
      expect(p, isA<CircuitBreakerResiliencePolicy>());
      expect(p.failureThreshold, 3);
    });

    test('custom shouldCount predicate is respected', () async {
      final registry = CircuitBreakerRegistry();
      const sentinel = HttpResponse(statusCode: 418);

      var counted = 0;
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-custom',
        failureThreshold: 3,
        registry: registry,
        shouldCount: (result, ex) {
          if (result is HttpResponse && result.statusCode == 418) {
            counted++;
            return true;
          }
          return false;
        },
      );

      // Each 418 response increments the counter.
      for (var i = 0; i < 3; i++) {
        await policy.execute(() async => sentinel);
      }
      expect(counted, 3);
      expect(policy.circuitState, CircuitState.open);
    });

    test('reset() manually closes the circuit', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-reset',
        failureThreshold: 1,
        registry: registry,
      );
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on _AppException {
        // expected
      }
      expect(policy.circuitState, CircuitState.open);

      policy.reset();
      expect(policy.circuitState, CircuitState.closed);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('CircuitBreakerResiliencePolicy — metrics', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('totalCalls reflects only forwarded calls, not rejections', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'metrics-total',
        failureThreshold: 10,
        registry: registry,
      );

      for (var i = 0; i < 3; i++) {
        await policy.execute(() async => 'ok');
      }

      final m = policy.metrics;
      expect(m.totalCalls, 3);
      expect(m.rejectedCalls, 0);
    });

    test('successfulCalls and failedCalls are tracked independently', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'metrics-success-fail',
        failureThreshold: 10,
        registry: registry,
      );

      await policy.execute(() async => 'ok');
      await policy.execute(() async => 'ok');
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      final m = policy.metrics;
      expect(m.totalCalls, 3);
      expect(m.successfulCalls, 2);
      expect(m.failedCalls, 1);
    });

    test('rejectedCalls increments when circuit is open', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'metrics-rejected',
        failureThreshold: 1,
        registry: registry,
      );

      // Trip the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Two open-circuit rejections.
      for (var i = 0; i < 2; i++) {
        try {
          await policy.execute(() async => 'nope');
        } on Object catch (_) {}
      }

      final m = policy.metrics;
      expect(m.rejectedCalls, 2);
      expect(m.totalCalls, 1); // only the tripping call was forwarded
    });

    test('consecutiveFailures tracks the current failure streak', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'metrics-consec',
        failureThreshold: 10,
        registry: registry,
      );

      for (var i = 0; i < 3; i++) {
        try {
          await policy.execute<void>(() async => throw const _AppException());
        } on Object catch (_) {}
      }
      expect(policy.metrics.consecutiveFailures, 3);

      // A success resets the consecutive-failure streak.
      await policy.execute(() async => 'ok');
      expect(policy.metrics.consecutiveFailures, 0);
    });

    test('lastTransitionAt is populated after the first state transition',
        () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'metrics-transition-time',
        failureThreshold: 1,
        registry: registry,
      );

      expect(policy.metrics.lastTransitionAt, isNull);

      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      final ts = policy.metrics.lastTransitionAt;
      expect(ts, isNotNull);
      expect(
        DateTime.now().difference(ts!),
        lessThan(const Duration(seconds: 2)),
      );
    });

    test('rejectedCalls includes half-open probe-slot-taken rejections',
        () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'metrics-halfopen-rejected',
        failureThreshold: 1,
        breakDuration: Duration.zero,
        registry: registry,
      );

      // Trip the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Slow probe takes the half-open slot.
      final probeGate = Completer<void>();
      final probeFuture = policy.execute(() async {
        await probeGate.future;
        return 'probe';
      });

      // Concurrent call is rejected because the slot is taken.
      try {
        await policy.execute(() async => 'concurrent');
      } on Object catch (_) {}

      probeGate.complete();
      await probeFuture;

      expect(policy.metrics.rejectedCalls, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('CircuitBreakerResiliencePolicy — state-change callbacks', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('onStateChange fires closed→open when failureThreshold is reached',
        () async {
      final transitions = <(CircuitState, CircuitState)>[];
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-sc-open',
        failureThreshold: 2,
        registry: registry,
        onStateChange: [(from, to) => transitions.add((from, to))],
      );

      for (var i = 0; i < 2; i++) {
        try {
          await policy.execute<void>(() async => throw const _AppException());
        } on Object catch (_) {}
      }

      expect(transitions, [(CircuitState.closed, CircuitState.open)]);
    });

    test('onStateChange fires open→halfOpen lazily when breakDuration elapses',
        () async {
      final transitions = <(CircuitState, CircuitState)>[];
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-sc-halfopen',
        failureThreshold: 1,
        breakDuration: Duration.zero,
        registry: registry,
        onStateChange: [(from, to) => transitions.add((from, to))],
      );

      // Trip the circuit → closed→open callback fires.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Reading circuitState triggers the lazy open→halfOpen transition.
      policy.circuitState;

      expect(
        transitions,
        containsAll([
          (CircuitState.closed, CircuitState.open),
          (CircuitState.open, CircuitState.halfOpen),
        ]),
      );
    });

    test('onStateChange fires halfOpen→closed after a successful probe',
        () async {
      final transitions = <(CircuitState, CircuitState)>[];
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-sc-close',
        failureThreshold: 1,
        breakDuration: Duration.zero,
        registry: registry,
        onStateChange: [(from, to) => transitions.add((from, to))],
      );

      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Successful probe closes the circuit.
      await policy.execute(() async => 'probe');

      expect(transitions.last, (CircuitState.halfOpen, CircuitState.closed));
    });

    test('onStateChange fires halfOpen→open after a failed probe', () async {
      final transitions = <(CircuitState, CircuitState)>[];
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-sc-reopen',
        failureThreshold: 1,
        breakDuration: Duration.zero,
        registry: registry,
        onStateChange: [(from, to) => transitions.add((from, to))],
      );

      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Failed probe re-opens the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      expect(transitions.last, (CircuitState.halfOpen, CircuitState.open));
    });

    test('multiple listeners all receive every transition in order', () async {
      final log1 = <(CircuitState, CircuitState)>[];
      final log2 = <(CircuitState, CircuitState)>[];
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-sc-multi',
        failureThreshold: 1,
        registry: registry,
        onStateChange: [
          (from, to) => log1.add((from, to)),
          (from, to) => log2.add((from, to)),
        ],
      );

      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      expect(log1, [(CircuitState.closed, CircuitState.open)]);
      expect(log2, [(CircuitState.closed, CircuitState.open)]);
      expect(log1, equals(log2));
    });

    test('Policy.circuitBreaker factory forwards onStateChange listeners',
        () async {
      final transitions = <(CircuitState, CircuitState)>[];
      final registry = CircuitBreakerRegistry();
      final policy = Policy.circuitBreaker(
        circuitName: 'cb-sc-factory',
        failureThreshold: 1,
        registry: registry,
        onStateChange: [(from, to) => transitions.add((from, to))],
      );

      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      expect(transitions, isNotEmpty);
      expect(transitions.first.$2, CircuitState.open);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('CircuitBreakerResiliencePolicy — half-open concurrency guard', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('second concurrent call during probe is rejected', () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-guard-reject',
        failureThreshold: 1,
        breakDuration: Duration.zero,
        registry: registry,
      );

      // Trip the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Start a slow probe — the half-open slot is claimed synchronously
      // before the first await inside execute().
      final probeGate = Completer<void>();
      final probeFuture = policy.execute(() async {
        await probeGate.future;
        return 'probe-done';
      });

      // Immediately attempt a second call — slot already taken.
      Object? rejection;
      try {
        await policy.execute(() async => 'concurrent');
      } on Object catch (e) {
        rejection = e;
      }

      expect(rejection, isA<CircuitOpenException>());

      // Allow the probe to finish.
      probeGate.complete();
      final probeResult = await probeFuture;
      expect(probeResult, 'probe-done');
      expect(policy.circuitState, CircuitState.closed);
    });

    test('after a successful probe the next call passes through normally',
        () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-guard-success',
        failureThreshold: 1,
        breakDuration: Duration.zero,
        registry: registry,
      );

      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Probe succeeds → circuit closes.
      await policy.execute(() async => 'probe');
      expect(policy.circuitState, CircuitState.closed);

      // Normal subsequent call is forwarded.
      final result = await policy.execute(() async => 'after-close');
      expect(result, 'after-close');
    });

    test('after a failed probe the circuit re-opens and slot is reset',
        () async {
      final registry = CircuitBreakerRegistry();
      final policy = CircuitBreakerResiliencePolicy(
        circuitName: 'cb-guard-reopen',
        failureThreshold: 1,
        breakDuration: const Duration(milliseconds: 50),
        registry: registry,
      );

      // Trip the circuit.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}

      // Wait for the half-open window.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(policy.circuitState, CircuitState.halfOpen);

      // Probe fails → re-opens.
      try {
        await policy.execute<void>(() async => throw const _AppException());
      } on Object catch (_) {}
      expect(policy.circuitState, CircuitState.open);

      // Wait again for a second half-open window.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // This time the probe succeeds → closed.
      final result = await policy.execute(() async => 'recovery');
      expect(result, 'recovery');
      expect(policy.circuitState, CircuitState.closed);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('TimeoutResiliencePolicy', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('completes normally when action finishes before timeout', () async {
      const policy = TimeoutResiliencePolicy(Duration(seconds: 5));
      final result = await policy.execute(() async => 'fast');
      expect(result, 'fast');
    });

    test('throws HttpTimeoutException when action exceeds timeout', () {
      fakeAsync((fake) {
        const policy = TimeoutResiliencePolicy(Duration(milliseconds: 100));
        Object? caught;
        policy.execute(() async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return 'slow';
        }).catchError((Object e) {
          caught = e;
          return '';
        });

        fake.elapse(const Duration(milliseconds: 200));
        expect(caught, isA<HttpTimeoutException>());
        final te = caught as HttpTimeoutException;
        expect(te.timeout, const Duration(milliseconds: 100));
      });
    });

    test('Policy.timeout factory produces TimeoutResiliencePolicy', () {
      final p = Policy.timeout(const Duration(seconds: 30));
      expect(p, isA<TimeoutResiliencePolicy>());
      expect(p.timeout, const Duration(seconds: 30));
    });

    test('per-attempt timeout via wrap keeps retrying until exhausted', () {
      fakeAsync((fake) {
        // timeout wraps each individual retry attempt (5s per attempt)
        final policy = Policy.retry(
          maxRetries: 2,
        ).wrap(Policy.timeout(const Duration(seconds: 5)));

        // Every action takes 10s — exceeds the 5s per-attempt timeout.
        Object? caught;
        policy.execute(() async {
          await Future<void>.delayed(const Duration(seconds: 10));
          return 'ok';
        }).catchError((Object e) {
          caught = e;
          return '';
        });

        // Advance 5s → first attempt times out, retry fires immediately.
        fake.elapse(const Duration(seconds: 5));
        // Advance 5s → second attempt times out.
        fake.elapse(const Duration(seconds: 5));
        // Advance 5s → third attempt times out.
        fake.elapse(const Duration(seconds: 5));
        fake.flushMicrotasks();

        expect(caught, isA<RetryExhaustedException>());
      });
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('BulkheadResiliencePolicy', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('allows up to maxConcurrency actions simultaneously', () async {
      final policy = BulkheadResiliencePolicy(maxConcurrency: 3);
      var active = 0;
      var maxActive = 0;

      Future<void> action() async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        active--;
      }

      await Future.wait(List.generate(3, (_) => policy.execute(action)));
      expect(maxActive, lessThanOrEqualTo(3));
    });

    test('rejects when both concurrency and queue are maxed out', () async {
      final policy = BulkheadResiliencePolicy(
        maxConcurrency: 1,
        maxQueueDepth: 0, // no queuing
      );

      // Hold the slot
      final blocker = Completer<void>();
      policy.execute(() async {
        await blocker.future;
      }).ignore();

      // One more slot, no queuing → rejected
      await expectLater(
        policy.execute(() async => 'rejected'),
        throwsA(isA<BulkheadRejectedException>()),
      );
      blocker.complete();
    });

    test('queued actions execute after active slots free up', () async {
      final policy = BulkheadResiliencePolicy(
        maxConcurrency: 1,
        maxQueueDepth: 2,
      );

      final order = <int>[];
      final blockers = List.generate(3, (_) => Completer<void>());

      // Schedule 3 tasks — only 1 runs at a time.
      final futures = List.generate(3, (i) {
        return policy.execute(() async {
          await blockers[i].future;
          order.add(i);
        });
      });

      // Release in order.
      for (final b in blockers) {
        b.complete();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(futures);

      expect(order, [0, 1, 2]);
    });

    test('Policy.bulkhead factory produces BulkheadResiliencePolicy', () {
      final p = Policy.bulkhead(maxConcurrency: 5, maxQueueDepth: 20);
      expect(p, isA<BulkheadResiliencePolicy>());
      expect(p.maxConcurrency, 5);
      expect(p.maxQueueDepth, 20);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyWrap — composition', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('wrap() produces a PolicyWrap', () {
      final outer = Policy.retry(maxRetries: 1);
      final inner = Policy.retry(maxRetries: 1);
      expect(outer.wrap(inner), isA<PolicyWrap>());
    });

    test('Policy.wrap([p]) returns the single policy unchanged', () {
      final p = Policy.retry(maxRetries: 1);
      expect(Policy.wrap([p]), same(p));
    });

    test('Policy.wrap([]) throws ArgumentError', () {
      expect(() => Policy.wrap([]), throwsA(isA<ArgumentError>()));
    });

    test('outer policy wraps inner: timeout around retry', () {
      fakeAsync((fake) {
        // Retry wraps timeout: each retry gets its own 1-second budget.
        final policy = Policy.retry(
          maxRetries: 2,
        ).wrap(Policy.timeout(const Duration(seconds: 1)));

        var calls = 0;
        Object? caught;
        policy.execute(() async {
          calls++;
          await Future<void>.delayed(
            const Duration(seconds: 2),
          ); // exceeds timeout
          return 'ok';
        }).catchError((Object e) {
          caught = e;
          return '';
        });

        // Each 1-second timeout fires, triggering retry.
        fake.elapse(const Duration(seconds: 1));
        fake.elapse(const Duration(seconds: 1));
        fake.elapse(const Duration(seconds: 1));
        fake.flushMicrotasks();

        expect(calls, 3); // 1 + 2 retries
        expect(caught, isA<RetryExhaustedException>());
      });
    });

    test('circuit breaker wrapped around retry short-circuits after threshold',
        () async {
      final registry = CircuitBreakerRegistry();
      final policy = Policy.circuitBreaker(
        circuitName: 'wrap-cb',
        failureThreshold: 1,
        registry: registry,
      ).wrap(Policy.retry(maxRetries: 2));

      var calls = 0;
      // First set of retries trips the circuit.
      await expectLater(
        policy.execute<void>(() async {
          calls++;
          throw const _AppException();
        }),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(calls, 3); // 1 initial + 2 retries

      // Now the circuit is open — next call rejected immediately.
      await expectLater(
        policy.execute(() async => 'nope'),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    test('Policy.wrap list composition is equivalent to chained .wrap()',
        () async {
      final registry1 = CircuitBreakerRegistry();
      final registry2 = CircuitBreakerRegistry();

      var count1 = 0;
      var count2 = 0;

      final chained = Policy.retry(maxRetries: 1).wrap(
        Policy.circuitBreaker(
          circuitName: 'wl-1',
          failureThreshold: 10,
          registry: registry1,
        ),
      );

      final listWrapped = Policy.wrap([
        Policy.retry(maxRetries: 1),
        Policy.circuitBreaker(
          circuitName: 'wl-2',
          failureThreshold: 10,
          registry: registry2,
        ),
      ]);

      // Both should retry exactly once and then exhaust.
      await expectLater(
        chained.execute<void>(() async {
          count1++;
          throw const _AppException();
        }),
        throwsA(isA<RetryExhaustedException>()),
      );

      await expectLater(
        listWrapped.execute<void>(() async {
          count2++;
          throw const _AppException();
        }),
        throwsA(isA<RetryExhaustedException>()),
      );

      expect(count1, count2);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyWrap — list-based introspection', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('policies getter exposes the full ordered chain outermost-first', () {
      final t = Policy.timeout(const Duration(seconds: 5));
      final cb = Policy.circuitBreaker(
        circuitName: 'insp-1',
        registry: CircuitBreakerRegistry(),
      );
      final r = Policy.retry(maxRetries: 2);

      final wrap = Policy.wrap([t, cb, r]) as PolicyWrap;

      expect(wrap.policies, hasLength(3));
      expect(wrap.policies[0], same(t));
      expect(wrap.policies[1], same(cb));
      expect(wrap.policies[2], same(r));
    });

    test(
        'fluent .wrap() chains produce the same flat policies list as Policy.wrap',
        () {
      final t = Policy.timeout(const Duration(seconds: 5));
      final cb = Policy.circuitBreaker(
        circuitName: 'insp-2',
        registry: CircuitBreakerRegistry(),
      );
      final r = Policy.retry(maxRetries: 2);

      final fluent = t.wrap(cb).wrap(r) as PolicyWrap;
      final list = Policy.wrap([t, cb, r]) as PolicyWrap;

      expect(fluent.policies.length, list.policies.length);
      for (var i = 0; i < fluent.policies.length; i++) {
        expect(fluent.policies[i], same(list.policies[i]));
      }
    });

    test('wrapping a PolicyWrap around another PolicyWrap flattens the lists',
        () {
      final a = Policy.retry(maxRetries: 1);
      final b = Policy.retry(maxRetries: 2);
      final c = Policy.retry(maxRetries: 3);
      final d = Policy.retry(maxRetries: 4);

      final ab = a.wrap(b) as PolicyWrap; // [a, b]
      final cd = c.wrap(d) as PolicyWrap; // [c, d]
      final abcd = ab.wrap(cd) as PolicyWrap; // should be [a, b, c, d]

      expect(abcd.policies, hasLength(4));
      expect(abcd.policies[0], same(a));
      expect(abcd.policies[1], same(b));
      expect(abcd.policies[2], same(c));
      expect(abcd.policies[3], same(d));
    });

    test('policies list is unmodifiable', () {
      final wrap = Policy.wrap([
        Policy.retry(maxRetries: 1),
        Policy.retry(maxRetries: 2),
      ]) as PolicyWrap;

      expect(
        () => (wrap.policies as List<Object>).add(
          Policy.retry(maxRetries: 3),
        ),
        throwsUnsupportedError,
      );
    });

    test('toString includes policy count and each policy on its own line', () {
      final wrap = Policy.wrap([
        Policy.timeout(const Duration(seconds: 5)),
        Policy.retry(maxRetries: 3),
      ]) as PolicyWrap;

      final s = wrap.toString();
      expect(s, contains('PolicyWrap(2 policies)'));
      expect(s, contains('TimeoutResiliencePolicy'));
      expect(s, contains('RetryResiliencePolicy'));
    });

    test('PolicyWrap requires at least 2 policies', () {
      expect(
        () => PolicyWrap([Policy.retry(maxRetries: 1)]),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyWrap — execution order verification', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('policies execute outermost-first, innermost-last', () async {
      final log = <String>[];

      final policies = ['outer', 'middle', 'inner'].map((name) {
        return _LoggingPolicy(name, log);
      }).toList();

      final wrap = Policy.wrap(policies);
      final result = await wrap.execute(() async {
        log.add('action');
        return 'done';
      });

      expect(result, 'done');
      expect(log, [
        'outer:before',
        'middle:before',
        'inner:before',
        'action',
        'inner:after',
        'middle:after',
        'outer:after',
      ]);
    });

    test('fluent .wrap() chain executes in the same order as Policy.wrap list',
        () async {
      final listLog = <String>[];
      final fluentLog = <String>[];

      Future<void> runWith(List<String> log) async {
        final policies =
            ['A', 'B', 'C'].map((n) => _LoggingPolicy(n, log)).toList();
        await Policy.wrap(policies).execute(() async {
          log.add('action');
        });
      }

      Future<void> runFluent(List<String> log) async {
        final a = _LoggingPolicy('A', log);
        final b = _LoggingPolicy('B', log);
        final c = _LoggingPolicy('C', log);
        await a.wrap(b).wrap(c).execute(() async {
          log.add('action');
        });
      }

      await runWith(listLog);
      await runFluent(fluentLog);

      expect(listLog, fluentLog);
    });

    test('innermost policy exception propagates outwards through all wrappers',
        () async {
      final seenBy = <String>[];

      final policies = ['outer', 'middle', 'inner']
          .map((n) => _CatchingPolicy(n, seenBy))
          .toList();

      final wrap = Policy.wrap(policies);

      await expectLater(
        wrap.execute<void>(() async => throw const _AppException('boom')),
        throwsA(isA<_AppException>()),
      );

      // Every policy in the chain saw the exception.
      expect(seenBy, containsAll(['outer', 'middle', 'inner']));
    });

    test('only the outermost policy can intercept and suppress exceptions',
        () async {
      // outer absorbs; middle and inner see the throw from the action.
      final seenBy = <String>[];
      var outerIntercepted = false;

      final wrap = Policy.wrap([
        _InterceptPolicy(onError: (_) => outerIntercepted = true),
        _CatchingPolicy('middle', seenBy),
        _CatchingPolicy('inner', seenBy),
      ]);

      // Should NOT throw — the outer policy swallows it.
      await wrap.execute<void>(() async => throw const _AppException());

      expect(outerIntercepted, isTrue);
      expect(seenBy, containsAll(['middle', 'inner']));
    });

    test('single-policy Policy.wrap returns the policy, not a PolicyWrap', () {
      final r = Policy.retry(maxRetries: 1);
      final result = Policy.wrap([r]);
      expect(result, same(r));
      expect(result, isNot(isA<PolicyWrap>()));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('ResiliencePipelineBuilder', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('build() with multiple policies returns a PolicyWrap', () {
      final p = ResiliencePipelineBuilder()
          .addRetry(maxRetries: 2)
          .addTimeout(const Duration(seconds: 5))
          .build();
      expect(p, isA<PolicyWrap>());
    });

    test('build() with a single addPolicy returns that policy directly', () {
      final inner = Policy.retry(maxRetries: 1);
      final result = ResiliencePipelineBuilder().addPolicy(inner).build();
      expect(result, same(inner));
    });

    test('build() with no policies throws StateError', () {
      expect(
        () => ResiliencePipelineBuilder().build(),
        throwsA(isA<StateError>()),
      );
    });

    test('addRetry adds a RetryResiliencePolicy at the next position', () {
      final builder = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 1))
          .addRetry(maxRetries: 3);

      final wrap = builder.build() as PolicyWrap;
      expect(wrap.policies[0], isA<TimeoutResiliencePolicy>());
      expect(wrap.policies[1], isA<RetryResiliencePolicy>());
    });

    test('addCircuitBreaker adds a CircuitBreakerResiliencePolicy', () {
      final wrap = ResiliencePipelineBuilder()
          .addCircuitBreaker(
            circuitName: 'bld-cb',
            registry: CircuitBreakerRegistry(),
          )
          .addRetry(maxRetries: 1)
          .build() as PolicyWrap;

      expect(wrap.policies[0], isA<CircuitBreakerResiliencePolicy>());
    });

    test('addTimeout adds a TimeoutResiliencePolicy', () {
      final wrap = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 10))
          .addRetry(maxRetries: 1)
          .build() as PolicyWrap;

      expect(wrap.policies[0], isA<TimeoutResiliencePolicy>());
      final t = wrap.policies[0] as TimeoutResiliencePolicy;
      expect(t.timeout, const Duration(seconds: 10));
    });

    test('addBulkhead adds a BulkheadResiliencePolicy', () {
      final wrap = ResiliencePipelineBuilder()
          .addBulkhead(maxConcurrency: 5)
          .addRetry(maxRetries: 1)
          .build() as PolicyWrap;

      expect(wrap.policies[0], isA<BulkheadResiliencePolicy>());
      final b = wrap.policies[0] as BulkheadResiliencePolicy;
      expect(b.maxConcurrency, 5);
    });

    test('addHttpRetry adds an HTTP-aware RetryResiliencePolicy', () async {
      var calls = 0;
      final policy = ResiliencePipelineBuilder().addHttpRetry(
        maxRetries: 2,
        backoff: const NoBackoff(),
        retryOnStatusCodes: [503],
      ).build();

      final response = await policy.execute(() async {
        calls++;
        return calls < 3
            ? const HttpResponse(statusCode: 503)
            : HttpResponse.ok();
      });
      expect(response.statusCode, 200);
      expect(calls, 3);
    });

    test('policies getter reflects the registered order', () {
      final builder = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 5))
          .addRetry(maxRetries: 1)
          .addBulkhead(maxConcurrency: 2);

      expect(builder.length, 3);
      expect(builder.policies[0], isA<TimeoutResiliencePolicy>());
      expect(builder.policies[1], isA<RetryResiliencePolicy>());
      expect(builder.policies[2], isA<BulkheadResiliencePolicy>());
    });

    test('clear() resets the builder to empty state', () {
      final builder = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 5))
          .clear();

      expect(builder.isEmpty, isTrue);
      expect(builder.length, 0);
    });

    test('builder is reusable after clear()', () {
      final builder =
          ResiliencePipelineBuilder().addTimeout(const Duration(seconds: 5));

      builder.clear().addRetry(maxRetries: 2).addRetry(maxRetries: 3);

      final wrap = builder.build() as PolicyWrap;
      expect(wrap.policies, hasLength(2));
      final r0 = wrap.policies[0] as RetryResiliencePolicy;
      expect(r0.maxRetries, 2);
    });

    test('built pipeline executes policies in declared order', () async {
      final log = <String>[];

      // Use addPolicy with our _LoggingPolicy helper to verify order.
      final policy = ResiliencePipelineBuilder()
          .addPolicy(_LoggingPolicy('first', log))
          .addPolicy(_LoggingPolicy('second', log))
          .addPolicy(_LoggingPolicy('third', log))
          .build();

      await policy.execute(() async {
        log.add('action');
        return 'ok';
      });

      expect(log, [
        'first:before',
        'second:before',
        'third:before',
        'action',
        'third:after',
        'second:after',
        'first:after',
      ]);
    });

    test('built pipeline equals equivalent Policy.wrap pipeline', () async {
      final builderLog = <String>[];
      final wrapLog = <String>[];

      Future<void> run(List<String> log) async {
        await Policy.wrap([
          _LoggingPolicy('A', log),
          _LoggingPolicy('B', log),
        ]).execute(() async {
          log.add('action');
        });
      }

      Future<void> runBuilder(List<String> log) async {
        await ResiliencePipelineBuilder()
            .addPolicy(_LoggingPolicy('A', log))
            .addPolicy(_LoggingPolicy('B', log))
            .build()
            .execute(() async {
          log.add('action');
        });
      }

      await run(wrapLog);
      await runBuilder(builderLog);

      expect(builderLog, equals(wrapLog));
    });

    test('toString is informative', () {
      final builder = ResiliencePipelineBuilder().addRetry(maxRetries: 1);
      expect(builder.toString(), contains('ResiliencePipelineBuilder'));
      expect(builder.toString(), contains('length=1'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Statelessness and reusability', () {
    // ──────────────────────────────────────────────════════════════════════════

    test('same RetryResiliencePolicy instance can be reused across calls',
        () async {
      const policy = RetryResiliencePolicy(maxRetries: 2);
      var totalCalls = 0;

      // First call fails on first attempt, succeeds on second.
      var firstCallAttempts = 0;
      await policy.execute(() async {
        totalCalls++;
        firstCallAttempts++;
        if (firstCallAttempts == 1) throw const _AppException();
        return 'first';
      });

      // Second call succeeds immediately.
      var secondCallAttempts = 0;
      await policy.execute(() async {
        totalCalls++;
        secondCallAttempts++;
        return 'second';
      });

      expect(firstCallAttempts, 2);
      expect(secondCallAttempts, 1);
      expect(totalCalls, 3);
    });

    test('concurrent executions on the same policy are independent', () async {
      const policy = RetryResiliencePolicy(maxRetries: 2);
      final counters = List.filled(5, 0);

      final futures = List.generate(5, (i) {
        return policy.execute(() async {
          counters[i]++;
          if (counters[i] < 2) throw const _AppException();
          return i;
        });
      });

      final results = await Future.wait(futures);
      expect(results, [0, 1, 2, 3, 4]);
      expect(counters, everyElement(2)); // each succeeded on its 2nd attempt
    });
  });
}
