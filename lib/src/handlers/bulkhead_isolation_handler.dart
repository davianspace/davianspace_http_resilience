import '../core/http_context.dart';
import '../core/http_response.dart';
import '../exceptions/bulkhead_rejected_exception.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/bulkhead_isolation_policy.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  BulkheadIsolationHandler
// ═══════════════════════════════════════════════════════════════════════════

/// A Completer-based bulkhead handler with metrics and zero-polling semaphore.
///
/// ## When to use this vs `BulkheadHandler`
///
/// Prefer `BulkheadIsolationHandler` when you want built-in metrics
/// (`activeCount`, `queuedCount`) or need to isolate separate resource
/// pools by name. For simple concurrency limiting, `BulkheadHandler`
/// is sufficient.
///
/// [BulkheadIsolationHandler] is configured by a [BulkheadIsolationPolicy]
/// and shares a single [BulkheadIsolationSemaphore] across all requests
/// processed by the same handler instance.
///
/// ## Failure modes
///
/// | Cause | [BulkheadRejectedException.reason] |
/// |---|---|
/// | Concurrency cap + queue both full | [BulkheadRejectionReason.queueFull] |
/// | Request timed out in the queue | [BulkheadRejectionReason.queueTimeout] |
///
/// ## Placement
///
/// Place [BulkheadIsolationHandler] **innermost** (closest to the terminal
/// handler) so that retry and fallback handlers see it as a single,
/// rate-limited unit:
///
/// ```dart
/// HttpClientFactory.create('catalog')
///     .withFallback(FallbackPolicy(...))   // 1. outermost
///     .withRetry(RetryPolicy.exponential(maxRetries: 3))
///     .withBulkheadIsolation(              // 2. innermost guard
///       BulkheadIsolationPolicy(
///         maxConcurrentRequests: 10,
///         maxQueueSize: 20,
///       ),
///     )
///     .build();
/// ```
///
/// ## Metrics
///
/// Inspect live counters via the [activeCount] and [queuedCount] getters,
/// or through the underlying [semaphore]:
///
/// ```dart
/// final handler = BulkheadIsolationHandler(policy);
/// print('active : ${handler.activeCount}');
/// print('queued : ${handler.queuedCount}');
/// print('free   : ${handler.semaphore.availableSlots}');
/// ```
final class BulkheadIsolationHandler extends DelegatingHandler {
  /// Creates a [BulkheadIsolationHandler] from [policy].
  BulkheadIsolationHandler(BulkheadIsolationPolicy policy)
      : _policy = policy,
        semaphore = BulkheadIsolationSemaphore(policy: policy);

  final BulkheadIsolationPolicy _policy;

  /// The semaphore that enforces concurrency limits for this handler.
  ///
  /// Inspect [BulkheadIsolationSemaphore.activeCount],
  /// [BulkheadIsolationSemaphore.queuedCount], and
  /// [BulkheadIsolationSemaphore.availableSlots] for real-time metrics.
  final BulkheadIsolationSemaphore semaphore;

  /// The number of requests currently executing inside the bulkhead.
  int get activeCount => semaphore.activeCount;

  /// The number of requests currently waiting in the queue.
  int get queuedCount => semaphore.queuedCount;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    // acquire() throws BulkheadRejectedException on queueFull or queueTimeout.
    await semaphore.acquire();

    try {
      return await innerHandler.send(context);
    } finally {
      semaphore.release();
    }
  }

  @override
  String toString() => 'BulkheadIsolationHandler($_policy)';
}
