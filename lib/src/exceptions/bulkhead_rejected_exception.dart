import 'http_resilience_exception.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  BulkheadRejectionReason
// ═══════════════════════════════════════════════════════════════════════════

/// Describes why a request was rejected by a bulkhead policy.
///
/// Carried by [BulkheadRejectedException] so callers can distinguish between
/// the two rejection causes and apply different recovery strategies.
enum BulkheadRejectionReason {
  /// The concurrent-execution cap **and** the request queue were both full.
  ///
  /// The request was dropped immediately without ever entering the queue.
  queueFull,

  /// The request entered the queue but could not acquire a slot within the
  /// configured `queueTimeout`.
  ///
  /// Consider increasing `queueTimeout` or reducing upstream call rates.
  queueTimeout,
}

// ═══════════════════════════════════════════════════════════════════════════
//  BulkheadRejectedException
// ═══════════════════════════════════════════════════════════════════════════

/// Thrown when a request is rejected by a bulkhead policy because the
/// maximum concurrency or queue depth has been reached, or because the
/// request timed out while waiting in the queue.
class BulkheadRejectedException extends HttpResilienceException {
  /// Creates a [BulkheadRejectedException].
  ///
  /// [maxConcurrency] — the configured ceiling for parallel executions.
  /// [maxQueueDepth]  — the configured ceiling for queued requests.
  /// [reason]         — why the request was rejected (defaults to
  ///                    [BulkheadRejectionReason.queueFull] for backwards
  ///                    compatibility).
  const BulkheadRejectedException({
    required this.maxConcurrency,
    required this.maxQueueDepth,
    this.reason = BulkheadRejectionReason.queueFull,
  }) : super(
          'Request rejected by bulkhead: concurrency=$maxConcurrency, '
          'queueDepth=$maxQueueDepth.',
        );

  /// Maximum number of concurrent executions allowed.
  final int maxConcurrency;

  /// Maximum number of requests that may wait in the queue.
  final int maxQueueDepth;

  /// The specific reason this request was rejected.
  ///
  /// Use this to distinguish between capacity-full rejections
  /// ([BulkheadRejectionReason.queueFull]) and timeout-based rejections
  /// ([BulkheadRejectionReason.queueTimeout]).
  final BulkheadRejectionReason reason;

  @override
  String toString() =>
      'BulkheadRejectedException: maxConcurrency=$maxConcurrency '
      'maxQueueDepth=$maxQueueDepth reason=${reason.name}';
}
