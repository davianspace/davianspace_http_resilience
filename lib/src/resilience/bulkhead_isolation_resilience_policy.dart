import '../exceptions/bulkhead_rejected_exception.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import '../policies/bulkhead_isolation_policy.dart';
import 'resilience_policy.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  BulkheadIsolationResiliencePolicy
// ═══════════════════════════════════════════════════════════════════════════

/// A [ResiliencePolicy] that limits concurrent executions to
/// [BulkheadIsolationPolicy.maxConcurrentRequests] and queues excess requests
/// up to [BulkheadIsolationPolicy.maxQueueSize].
///
/// ## Overview
///
/// [BulkheadIsolationResiliencePolicy] wraps **any** [Future]-returning action
/// — not just HTTP requests — making it suitable for general-purpose
/// concurrency control.  It is the free-standing counterpart to
/// [`BulkheadIsolationHandler`], which operates inside the HTTP handler pipeline.
///
/// ## Construction
///
/// ```dart
/// final policy = BulkheadIsolationResiliencePolicy(
///   maxConcurrentRequests: 10,
///   maxQueueSize: 20,
///   queueTimeout: Duration(seconds: 5),
///   onRejected: (reason) => log.warning('Bulkhead rejected: $reason'),
/// );
///
/// // or via the factory
/// final policy = Policy.bulkheadIsolation(
///   maxConcurrentRequests: 10,
///   maxQueueSize: 20,
/// );
/// ```
///
/// ## Execution
///
/// ```dart
/// // At most 10 calls execute concurrently; up to 20 more wait in queue.
/// final result = await policy.execute(() => expensiveOperation());
/// ```
///
/// ## Rejection
///
/// When capacity is exceeded a [BulkheadRejectedException] is thrown.
/// Inspect [BulkheadRejectedException.reason] to determine the cause:
///
/// ```dart
/// try {
///   await policy.execute(() => downstream());
/// } on BulkheadRejectedException catch (e) {
///   switch (e.reason) {
///     case BulkheadRejectionReason.queueFull:
///       // Drop and return 503
///       break;
///     case BulkheadRejectionReason.queueTimeout:
///       // Queue was full for too long — return 504
///       break;
///   }
/// }
/// ```
///
/// ## Composition
///
/// Place the policy **innermost** (last in [`Policy.wrap`]) so retries and
/// fallbacks operate on top of it:
///
/// ```dart
/// final pipeline = Policy.wrap([
///   Policy.fallback(fallbackAction: (_, __) async => HttpResponse.cached('cached')),
///   Policy.retry(maxRetries: 3),
///   Policy.bulkheadIsolation(maxConcurrentRequests: 5, maxQueueSize: 10),
/// ]);
/// ```
///
/// ## Statelessness
///
/// [BulkheadIsolationResiliencePolicy] is **stateful** — it owns a
/// [BulkheadIsolationSemaphore] and its active/queued counters change with
/// each request.  The instance is safe to share across concurrent callers
/// (that is the purpose of the semaphore).
final class BulkheadIsolationResiliencePolicy extends ResiliencePolicy {
  /// Creates a [BulkheadIsolationResiliencePolicy] from individual parameters.
  ///
  /// [maxConcurrentRequests] — maximum simultaneous executions (≥ 1).
  /// [maxQueueSize]          — maximum requests queued for execution (≥ 0).
  ///                           Set to `0` to reject overflow immediately.
  /// [queueTimeout]          — maximum wait time in the queue before the
  ///                           request is rejected.
  /// [onRejected]            — optional side-effect callback on rejection.
  BulkheadIsolationResiliencePolicy({
    int maxConcurrentRequests = 10,
    int maxQueueSize = 100,
    Duration queueTimeout = const Duration(seconds: 10),
    BulkheadRejectedCallback? onRejected,
    ResilienceEventHub? eventHub,
  }) : this.fromPolicy(
          BulkheadIsolationPolicy(
            maxConcurrentRequests: maxConcurrentRequests,
            maxQueueSize: maxQueueSize,
            queueTimeout: queueTimeout,
            onRejected: onRejected,
          ),
          eventHub: eventHub,
        );

  /// Creates a [BulkheadIsolationResiliencePolicy] from a
  /// [BulkheadIsolationPolicy] config object.
  BulkheadIsolationResiliencePolicy.fromPolicy(
    BulkheadIsolationPolicy policy, {
    ResilienceEventHub? eventHub,
  })  : _policy = policy,
        _eventHub = eventHub,
        semaphore = BulkheadIsolationSemaphore(policy: policy);

  final BulkheadIsolationPolicy _policy;
  final ResilienceEventHub? _eventHub;

  /// The semaphore enforcing concurrency limits.
  ///
  /// Inspect [BulkheadIsolationSemaphore.activeCount],
  /// [BulkheadIsolationSemaphore.queuedCount], and
  /// [BulkheadIsolationSemaphore.availableSlots] for real-time metrics.
  final BulkheadIsolationSemaphore semaphore;

  /// The number of actions currently executing inside the bulkhead.
  int get activeCount => semaphore.activeCount;

  /// The number of actions currently waiting in the queue.
  int get queuedCount => semaphore.queuedCount;

  /// Optional `ResilienceEventHub` receiving a `BulkheadRejectedEvent` on
  /// every rejection.
  ///
  /// Events are dispatched via `scheduleMicrotask` and never block execution.
  ResilienceEventHub? get eventHub => _eventHub;

  // --------------------------------------------------------------------------
  // Execution
  // --------------------------------------------------------------------------

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    // acquire() throws BulkheadRejectedException on overflow or timeout.
    try {
      await semaphore.acquire();
    } on BulkheadRejectedException catch (e) {
      _eventHub?.emit(
        BulkheadRejectedEvent(
          maxConcurrency: _policy.maxConcurrentRequests,
          maxQueueDepth: _policy.maxQueueSize,
          reason: e.reason,
          source: 'BulkheadIsolationResiliencePolicy',
        ),
      );
      rethrow;
    }

    try {
      return await action();
    } finally {
      semaphore.release();
    }
  }

  @override
  String toString() => 'BulkheadIsolationResiliencePolicy('
      'maxConcurrentRequests=${_policy.maxConcurrentRequests}, '
      'maxQueueSize=${_policy.maxQueueSize})';
}
