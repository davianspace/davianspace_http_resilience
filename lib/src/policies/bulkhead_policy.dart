import 'dart:async';
import 'dart:collection';

import 'bulkhead_signals.dart';

/// Immutable configuration for the bulkhead (concurrency-limiter) policy.
///
/// The bulkhead pattern isolates sections of the application from cascading
/// failures by capping how many requests execute in parallel and how many
/// may queue for execution.
///
/// When both limits are exceeded the pipeline throws a
/// [`BulkheadRejectedException`] immediately so callers can fail fast and
/// surface back-pressure to the client.
///
/// ```dart
/// final policy = BulkheadPolicy(
///   maxConcurrency: 10,
///   maxQueueDepth: 50,
/// );
/// ```
final class BulkheadPolicy {
  const BulkheadPolicy({
    this.maxConcurrency = 10,
    this.maxQueueDepth = 100,
    this.queueTimeout = const Duration(seconds: 10),
  });

  /// The maximum number of requests that may execute concurrently.
  final int maxConcurrency;

  /// The maximum number of requests that may wait in the queue when
  /// [maxConcurrency] has been reached.
  final int maxQueueDepth;

  /// How long a queued request may wait before being rejected.
  final Duration queueTimeout;

  @override
  String toString() => 'BulkheadPolicy(maxConcurrency=$maxConcurrency, '
      'maxQueueDepth=$maxQueueDepth, '
      'queueTimeout=${queueTimeout.inMilliseconds}ms)';
}

// ---------------------------------------------------------------------------
// Semaphore implementation (no external deps)
// ---------------------------------------------------------------------------

/// A simple async semaphore that enforces [BulkheadPolicy] concurrency limits.
///
/// One [BulkheadSemaphore] instance should be shared across all requests
/// governed by the same policy (typically held by the handler instance).
final class BulkheadSemaphore {
  BulkheadSemaphore({required BulkheadPolicy policy})
      : _policy = policy,
        _running = 0,
        _queue = Queue<_QueueEntry>();

  final BulkheadPolicy _policy;
  int _running;
  final Queue<_QueueEntry> _queue;

  /// The number of requests currently executing.
  int get running => _running;

  /// The number of requests waiting in the queue.
  int get queued => _queue.length;

  /// Acquires a slot, waiting if necessary.
  ///
  /// Throws [`BulkheadQueueFullException`] when [`maxQueueDepth`] is exceeded,
  /// or [`BulkheadQueueTimeoutException`] when [`queueTimeout`] expires while
  /// waiting.
  Future<void> acquire() async {
    if (_running < _policy.maxConcurrency) {
      _running++;
      return;
    }

    if (_queue.length >= _policy.maxQueueDepth) {
      throw const BulkheadQueueFullSignal();
    }

    final entry = _QueueEntry();
    _queue.add(entry);

    try {
      await entry.completer.future.timeout(
        _policy.queueTimeout,
        onTimeout: () => throw const BulkheadQueueTimeoutSignal(),
      );
    } on BulkheadQueueTimeoutSignal {
      entry.cancelled = true;
      _queue.remove(entry);
      rethrow;
    }
  }

  /// Releases a slot and wakes the next non-cancelled queued request, if any.
  void release() {
    while (_queue.isNotEmpty) {
      final next = _queue.removeFirst();
      if (!next.cancelled) {
        // Transfer the slot directly — active count stays the same.
        next.completer.complete();
        return;
      }
      // Waiter already timed out — skip it.
    }
    _running = (_running - 1).clamp(0, _policy.maxConcurrency);
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

final class _QueueEntry {
  /// The completer whose future the waiter is suspended on.
  final Completer<void> completer = Completer<void>();

  /// Set to `true` when the waiter's queue timeout has expired.
  ///
  /// A cancelled waiter is skipped by [BulkheadSemaphore.release] so that
  /// a slot is not transferred to it after it has already been rejected.
  bool cancelled = false;
}
