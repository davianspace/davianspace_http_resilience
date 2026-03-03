import '../core/http_context.dart';
import '../core/http_response.dart';
import '../exceptions/bulkhead_rejected_exception.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/bulkhead_policy.dart';
import '../policies/bulkhead_signals.dart';

/// A simple queue-based bulkhead handler that limits concurrent HTTP requests.
///
/// ## When to use this vs `BulkheadIsolationHandler`
///
/// Use `BulkheadHandler` for simple concurrency limiting with FIFO ordering.
/// Use `BulkheadIsolationHandler` when you need:
/// - Observability metrics (queued count, rejected count)
/// - Zero-polling Completer-based semaphore (slightly lower CPU overhead)
/// - Per-semaphore isolation for named resource pools
///
/// `BulkheadHandler` uses an internal `BulkheadSemaphore` to cap the number
/// of parallel requests. Requests beyond `BulkheadPolicy.maxConcurrency` are
/// queued up to `BulkheadPolicy.maxQueueDepth`; excess requests or requests
/// that time out in the queue raise `BulkheadRejectedException`.
///
/// ### Example
/// ```dart
/// final policy = BulkheadPolicy(maxConcurrency: 10, maxQueueDepth: 50);
/// final handler = BulkheadHandler(policy);
/// ```
final class BulkheadHandler extends DelegatingHandler {
  BulkheadHandler(BulkheadPolicy policy)
      : _semaphore = BulkheadSemaphore(policy: policy),
        _policy = policy,
        super();

  final BulkheadPolicy _policy;
  final BulkheadSemaphore _semaphore;

  /// Current number of requests executing inside the bulkhead.
  int get activeCount => _semaphore.running;

  /// Current number of requests queued waiting for a slot.
  int get queuedCount => _semaphore.queued;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    try {
      await _semaphore.acquire();
    } on BulkheadQueueFullSignal {
      throw BulkheadRejectedException(
        maxConcurrency: _policy.maxConcurrency,
        maxQueueDepth: _policy.maxQueueDepth,
      );
    } on BulkheadQueueTimeoutSignal {
      throw BulkheadRejectedException(
        maxConcurrency: _policy.maxConcurrency,
        maxQueueDepth: _policy.maxQueueDepth,
        reason: BulkheadRejectionReason.queueTimeout,
      );
    }

    try {
      return await innerHandler.send(context);
    } finally {
      _semaphore.release();
    }
  }
}
