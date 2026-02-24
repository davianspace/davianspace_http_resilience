import 'dart:async';

import '../exceptions/bulkhead_rejected_exception.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import 'resilience_policy.dart';

/// A [ResiliencePolicy] that limits concurrent executions to [maxConcurrency].
///
/// Requests that arrive when [maxConcurrency] slots are occupied are queued
/// up to [maxQueueDepth].  Requests rejected because the queue is full, or
/// that wait longer than [queueTimeout] in the queue, are rejected with
/// [BulkheadRejectedException].
///
/// **Unlike the handler-based [`BulkheadHandler`]**, [`BulkheadResiliencePolicy`]
/// maintains its own internal semaphore so it can wrap any `Future<T>`
/// callback — not only [`HttpHandler.send()`].
///
/// ### Usage
/// ```dart
/// final policy = BulkheadResiliencePolicy(
///   maxConcurrency: 10,
///   maxQueueDepth: 50,
/// );
///
/// // At most 10 calls execute concurrently; up to 50 more wait in queue.
/// final result = await policy.execute(() => expensiveOperation());
/// ```
final class BulkheadResiliencePolicy extends ResiliencePolicy {
  /// Creates a [BulkheadResiliencePolicy].
  ///
  /// [maxConcurrency] — maximum parallel executions (must be ≥ 1).
  /// [maxQueueDepth]  — maximum waiting requests (0 disables queuing).
  /// [queueTimeout]   — maximum time a request may wait in the queue.
  BulkheadResiliencePolicy({
    required this.maxConcurrency,
    this.maxQueueDepth = 100,
    this.queueTimeout = const Duration(seconds: 10),
    this.eventHub,
  })  : assert(maxConcurrency >= 1, 'maxConcurrency must be at least 1'),
        assert(maxQueueDepth >= 0, 'maxQueueDepth must be non-negative'),
        _semaphore = _AsyncSemaphore(maxConcurrency);

  /// Maximum number of actions executing concurrently.
  final int maxConcurrency;

  /// Maximum number of actions queued waiting for a slot.
  final int maxQueueDepth;

  /// How long a queued request may wait before being rejected.
  final Duration queueTimeout;

  /// Optional [ResilienceEventHub] that receives a [BulkheadRejectedEvent]
  /// whenever a request is rejected.
  ///
  /// Events are dispatched via [scheduleMicrotask] and never block execution.
  final ResilienceEventHub? eventHub;

  final _AsyncSemaphore _semaphore;

  /// Number of actions currently executing inside the bulkhead.
  int get activeCount => _semaphore.activeCount;

  /// Number of actions currently waiting in the queue.
  int get queuedCount => _semaphore.queuedCount;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    // Reject immediately if the queue is already full.
    if (_semaphore.queuedCount >= maxQueueDepth &&
        _semaphore.activeCount >= maxConcurrency) {
      eventHub?.emit(
        BulkheadRejectedEvent(
          maxConcurrency: maxConcurrency,
          maxQueueDepth: maxQueueDepth,
          source: 'BulkheadResiliencePolicy',
        ),
      );
      throw BulkheadRejectedException(
        maxConcurrency: maxConcurrency,
        maxQueueDepth: maxQueueDepth,
      );
    }

    // Wait for a semaphore slot, respecting the queue timeout.
    final acquired = await _semaphore
        .acquire()
        .timeout(queueTimeout, onTimeout: () => false);

    if (!acquired) {
      eventHub?.emit(
        BulkheadRejectedEvent(
          maxConcurrency: maxConcurrency,
          maxQueueDepth: maxQueueDepth,
          source: 'BulkheadResiliencePolicy',
        ),
      );
      throw BulkheadRejectedException(
        maxConcurrency: maxConcurrency,
        maxQueueDepth: maxQueueDepth,
      );
    }

    try {
      return await action();
    } finally {
      _semaphore.release();
    }
  }

  @override
  String toString() => 'BulkheadResiliencePolicy('
      'maxConcurrency=$maxConcurrency, maxQueueDepth=$maxQueueDepth)';
}

// ---------------------------------------------------------------------------
// Internal async semaphore
// ---------------------------------------------------------------------------

/// A counting semaphore built with [Completer]s.
///
/// `acquire()` returns `true` when the slot is taken within the timeout, or
/// `false` when the external `.timeout(…, onTimeout: () => false)` fires.
final class _AsyncSemaphore {
  _AsyncSemaphore(this._limit);

  final int _limit;
  int _active = 0;
  final _queue = <Completer<bool>>[];

  int get activeCount => _active;
  int get queuedCount => _queue.length;

  /// Acquires a slot.  Returns a future that completes with `true` when the
  /// slot is granted; the caller should wrap it with `.timeout(…)`.
  Future<bool> acquire() {
    if (_active < _limit) {
      _active++;
      return Future.value(true);
    }
    final completer = Completer<bool>();
    _queue.add(completer);
    return completer.future;
  }

  /// Releases a previously acquired slot and unblocks the next waiter.
  void release() {
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      // Grant the slot directly to the next waiter without decrementing
      // (slot transferred rather than released + re-acquired).
      if (!next.isCompleted) next.complete(true);
    } else {
      _active--;
    }
  }
}
