// Internal signal exceptions used by BulkheadSemaphore and caught by
// BulkheadHandler.  They are never exposed to callers — the handler
// translates them into [BulkheadRejectedException].
//
// Having them in a single file allows the policy semaphore (in
// bulkhead_policy.dart) and the handler (in bulkhead_handler.dart) to share
// the exact same type identity, which is required for Dart's `on T` catch
// clauses to match.

/// Thrown when the bulkhead queue is already full and an extra request arrives.
class BulkheadQueueFullSignal implements Exception {
  const BulkheadQueueFullSignal();
}

/// Thrown when a queued request has been waiting longer than [`queueTimeout`].
class BulkheadQueueTimeoutSignal implements Exception {
  const BulkheadQueueTimeoutSignal();
}
