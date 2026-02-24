import 'dart:async';
import 'dart:collection';

import '../exceptions/bulkhead_rejected_exception.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Typedefs
// ═══════════════════════════════════════════════════════════════════════════

/// Callback invoked when a request is rejected by a [BulkheadIsolationPolicy].
///
/// [reason] indicates whether the rejection was due to a full queue
/// ([BulkheadRejectionReason.queueFull]) or a queue timeout
/// ([BulkheadRejectionReason.queueTimeout]).
///
/// Use this for logging, metrics, or circuit-breaker integration.
///
/// ```dart
/// onRejected: (reason) =>
///     metrics.increment('bulkhead.rejected.${reason.name}'),
/// ```
typedef BulkheadRejectedCallback = void Function(
  BulkheadRejectionReason reason,
);

// ═══════════════════════════════════════════════════════════════════════════
//  BulkheadIsolationPolicy
// ═══════════════════════════════════════════════════════════════════════════

/// Immutable configuration for the [`BulkheadIsolationHandler`] and
/// [`BulkheadIsolationResiliencePolicy`].
///
/// The *bulkhead isolation* pattern limits how many requests enter a
/// downstream service concurrently, maintaining a bounded queue for
/// excess requests so they can absorb short bursts rather than failing
/// immediately.
///
/// ## Configuration
///
/// ```dart
/// final policy = BulkheadIsolationPolicy(
///   maxConcurrentRequests: 10,   // at most 10 in-flight requests
///   maxQueueSize: 20,            // at most 20 more waiting
///   queueTimeout: Duration(seconds: 5),
///   onRejected: (reason) => log.warning('Bulkhead rejected: $reason'),
/// );
/// ```
///
/// ## Limits
///
/// | Queue depth | [maxQueueSize] waiting requests |
/// |---|---|
/// | Concurrency | [maxConcurrentRequests] parallel executions |
///
/// When both limits are full incoming requests are rejected immediately with
/// [BulkheadRejectedException] whose [BulkheadRejectedException.reason] is
/// [BulkheadRejectionReason.queueFull].
///
/// When a request waits longer than [queueTimeout] it is likewise rejected,
/// with reason [BulkheadRejectionReason.queueTimeout].
///
/// ## Comparison with [`BulkheadPolicy`]
///
/// [BulkheadIsolationPolicy] exposes HTTP-oriented parameter names
/// (`maxConcurrentRequests` / `maxQueueSize`) and carries an optional
/// [onRejected] callback.  Internally it drives [BulkheadIsolationSemaphore],
/// which uses a zero-polling Completer-based queue instead of a spin-wait.
final class BulkheadIsolationPolicy {
  /// Creates a [BulkheadIsolationPolicy].
  ///
  /// [maxConcurrentRequests] — maximum simultaneous executions (≥ 1).
  /// [maxQueueSize]          — maximum requests waiting when the concurrency
  ///                           cap is reached (0 = reject immediately).
  /// [queueTimeout]          — maximum wait time in the queue before a
  ///                           [BulkheadRejectedException] is thrown.
  /// [onRejected]            — optional callback fired on every rejection,
  ///                           before the exception is thrown.
  const BulkheadIsolationPolicy({
    this.maxConcurrentRequests = 10,
    this.maxQueueSize = 100,
    this.queueTimeout = const Duration(seconds: 10),
    this.onRejected,
  })  : assert(
          maxConcurrentRequests >= 1,
          'maxConcurrentRequests must be at least 1',
        ),
        assert(
          maxQueueSize >= 0,
          'maxQueueSize must be non-negative',
        );

  /// Maximum number of requests executing concurrently.
  final int maxConcurrentRequests;

  /// Maximum number of requests queued waiting for a concurrency slot.
  ///
  /// Set to `0` to disable queuing (every overflow is rejected immediately).
  final int maxQueueSize;

  /// Maximum time a queued request may wait before it is rejected with
  /// [BulkheadRejectionReason.queueTimeout].
  final Duration queueTimeout;

  /// Optional callback invoked whenever a request is rejected.
  ///
  /// Receives the [BulkheadRejectionReason] so callers can distinguish between
  /// queue-full and timeout-based rejections.  Must not throw.
  final BulkheadRejectedCallback? onRejected;

  @override
  String toString() => 'BulkheadIsolationPolicy('
      'maxConcurrentRequests=$maxConcurrentRequests, '
      'maxQueueSize=$maxQueueSize, '
      'queueTimeout=${queueTimeout.inMilliseconds}ms)';
}

// ═══════════════════════════════════════════════════════════════════════════
//  BulkheadIsolationSemaphore
// ═══════════════════════════════════════════════════════════════════════════

/// An efficient, zero-polling async semaphore that enforces the concurrency
/// limits of a [BulkheadIsolationPolicy].
///
/// ## Efficiency
///
/// The semaphore uses [Completer]-based signalling — no spin-wait or
/// periodic timer.  When a slot is released, the next non-cancelled waiter
/// is granted the slot in O(1) amortised time via a [Queue].
///
/// ## Usage
///
/// One [BulkheadIsolationSemaphore] instance should be shared by all
/// requests governed by the same policy.  It is typically held by the
/// [`BulkheadIsolationHandler`] or [`BulkheadIsolationResiliencePolicy`]
/// that were constructed from the policy.
///
/// ```dart
/// final policy = BulkheadIsolationPolicy(maxConcurrentRequests: 5);
/// final semaphore = BulkheadIsolationSemaphore(policy: policy);
///
/// await semaphore.acquire();
/// try {
///   await doWork();
/// } finally {
///   semaphore.release();
/// }
/// ```
///
/// ## Metrics
///
/// ```dart
/// print('active : ${semaphore.activeCount}');
/// print('queued : ${semaphore.queuedCount}');
/// print('free   : ${semaphore.availableSlots}');
/// ```
final class BulkheadIsolationSemaphore {
  /// Creates a semaphore from [policy].
  BulkheadIsolationSemaphore({required BulkheadIsolationPolicy policy})
      : _policy = policy;

  final BulkheadIsolationPolicy _policy;

  int _active = 0;
  int _queued = 0;
  final _waiters = Queue<_Waiter>();

  // --------------------------------------------------------------------------
  // Metrics
  // --------------------------------------------------------------------------

  /// The number of requests currently holding a concurrency slot.
  int get activeCount => _active;

  /// The number of requests currently waiting in the queue.
  int get queuedCount => _queued;

  /// The number of concurrency slots not yet in use.
  int get availableSlots => (_policy.maxConcurrentRequests - _active)
      .clamp(0, _policy.maxConcurrentRequests);

  /// Whether the concurrency cap has been reached.
  bool get isAtCapacity => _active >= _policy.maxConcurrentRequests;

  // --------------------------------------------------------------------------
  // Acquire / Release
  // --------------------------------------------------------------------------

  /// Attempts to acquire a slot, queuing the caller if the concurrency cap
  /// has been reached.
  ///
  /// Throws [BulkheadRejectedException] when:
  /// - The queue is already full ([BulkheadRejectionReason.queueFull]).
  /// - The caller waited longer than [BulkheadIsolationPolicy.queueTimeout]
  ///   ([BulkheadRejectionReason.queueTimeout]).
  Future<void> acquire() async {
    // Fast-path: slot immediately available.
    if (_active < _policy.maxConcurrentRequests) {
      _active++;
      return;
    }

    // Queue full — reject immediately.
    if (_queued >= _policy.maxQueueSize) {
      _policy.onRejected?.call(BulkheadRejectionReason.queueFull);
      throw BulkheadRejectedException(
        maxConcurrency: _policy.maxConcurrentRequests,
        maxQueueDepth: _policy.maxQueueSize,
      );
    }

    // Enter the queue.
    final waiter = _Waiter();
    _waiters.addLast(waiter);
    _queued++;

    try {
      await waiter.completer.future.timeout(_policy.queueTimeout);
      // When we arrive here the slot has already been transferred to us
      // by [release()]; the active count was not decremented.
    } on TimeoutException {
      waiter.cancelled = true;
      _queued--;
      _policy.onRejected?.call(BulkheadRejectionReason.queueTimeout);
      throw BulkheadRejectedException(
        maxConcurrency: _policy.maxConcurrentRequests,
        maxQueueDepth: _policy.maxQueueSize,
        reason: BulkheadRejectionReason.queueTimeout,
      );
    }
  }

  /// Releases the slot held by the current caller.
  ///
  /// If there are waiters in the queue, the slot is transferred directly
  /// to the first non-cancelled waiter (active count is unchanged).
  /// If no valid waiter exists, the active count is decremented.
  void release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.cancelled) {
        _queued--;
        // Transfer slot: complete the waiter's future.  Active count stays
        // the same because we are handing our slot directly to the waiter.
        next.completer.complete();
        return;
      }
      // Waiter was already cancelled (timed out) — skip to next.
      // _queued was already decremented in the timeout handler.
    }
    // No valid waiter — return the slot to the pool.
    _active--;
  }
}

// ─── Internal waiter ────────────────────────────────────────────────────────

final class _Waiter {
  final completer = Completer<void>();

  /// Set to `true` when the waiter's timeout has expired.
  ///
  /// A cancelled waiter will be skipped by [BulkheadIsolationSemaphore.release].
  bool cancelled = false;
}
