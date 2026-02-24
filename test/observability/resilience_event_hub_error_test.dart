// Tests for ResilienceEventHub(onListenerError:) added in Phase 7.1.

import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// Drains the microtask queue so async listener callbacks can settle.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  //  Default behaviour (no callback)
  // ──────────────────────────────────────────────────────────────────────────

  group('ResilienceEventHub — default (no onListenerError)', () {
    test('sync listener error is silently discarded', () async {
      final hub = ResilienceEventHub();
      hub.on<RetryEvent>((_) => throw StateError('should be swallowed'));
      // Must not throw or escape the test.
      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();
    });

    test('async listener error is silently discarded', () async {
      final hub = ResilienceEventHub();
      hub.on<RetryEvent>((_) async => throw StateError('async — swallowed'));
      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();
      await _pump();
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Sync listener errors
  // ──────────────────────────────────────────────────────────────────────────

  group('ResilienceEventHub — onListenerError with sync throw', () {
    test('callback is invoked with the thrown error', () async {
      final errors = <Object>[];
      final hub = ResilienceEventHub(onListenerError: (e, _) => errors.add(e));

      hub.on<RetryEvent>((_) => throw StateError('sync'));
      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();

      expect(errors, hasLength(1));
      expect(errors.first, isA<StateError>());
    });

    test('callback receives a non-null StackTrace', () async {
      final stacks = <StackTrace>[];
      final hub = ResilienceEventHub(
        onListenerError: (_, st) => stacks.add(st),
      );

      hub.on<RetryEvent>((_) => throw Exception('with stack'));
      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();

      expect(stacks, hasLength(1));
      expect(stacks.first, isA<StackTrace>());
    });

    test('remaining listeners still execute after one throws', () async {
      final called = <int>[];
      final hub = ResilienceEventHub(onListenerError: (_, __) {});

      hub
        ..on<RetryEvent>((_) {
          called.add(1);
          throw Exception('listener 1 throws');
        })
        ..on<RetryEvent>((_) => called.add(2))
        ..on<RetryEvent>((_) => called.add(3));

      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();

      expect(called, containsAllInOrder([1, 2, 3]));
    });

    test('multiple sync errors each invoke the callback', () async {
      final errors = <Object>[];
      final hub = ResilienceEventHub(onListenerError: (e, _) => errors.add(e));

      hub
        ..on<RetryEvent>((_) => throw ArgumentError('a'))
        ..on<RetryEvent>((_) => throw ArgumentError('b'));

      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();

      expect(errors, hasLength(2));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Async listener errors (Future-based)
  // ──────────────────────────────────────────────────────────────────────────

  group('ResilienceEventHub — onListenerError with async throw', () {
    test('async callback error is routed to onListenerError', () async {
      final errors = <Object>[];
      final hub = ResilienceEventHub(onListenerError: (e, _) => errors.add(e));

      hub.on<RetryEvent>((_) async => throw StateError('async'));
      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();
      await _pump(); // extra pump for future chain

      expect(errors, hasLength(1));
      expect(errors.first, isA<StateError>());
    });

    test('async error StackTrace is forwarded', () async {
      final stacks = <StackTrace>[];
      final hub = ResilienceEventHub(
        onListenerError: (_, st) => stacks.add(st),
      );

      hub.on<RetryEvent>((_) async => throw Exception('async stack'));
      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();
      await _pump();

      expect(stacks, hasLength(1));
    });

    test('succeeding async listener runs alongside throwing async listener',
        () async {
      final called = <int>[];
      final hub = ResilienceEventHub(onListenerError: (_, __) {});

      hub
        ..on<RetryEvent>((_) async {
          called.add(1);
          throw Exception('listener 1 async throw');
        })
        ..on<RetryEvent>((_) async => called.add(2));

      hub.emit(
        RetryEvent(attemptNumber: 1, maxAttempts: 3, delay: Duration.zero),
      );
      await _pump();
      await _pump();

      expect(called, containsAll([1, 2]));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Different event types
  // ──────────────────────────────────────────────────────────────────────────

  group('ResilienceEventHub — onListenerError with different event types', () {
    test('error in CircuitOpenEvent listener is routed', () async {
      final errors = <Object>[];
      final hub = ResilienceEventHub(onListenerError: (e, _) => errors.add(e));

      hub.on<CircuitOpenEvent>((_) => throw StateError('cb error'));
      hub.emit(
        CircuitOpenEvent(
          circuitName: 'svc',
          previousState: CircuitState.closed,
          consecutiveFailures: 5,
        ),
      );
      await _pump();

      expect(errors, hasLength(1));
    });
  });
}
