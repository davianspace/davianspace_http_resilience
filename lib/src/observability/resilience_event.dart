import '../exceptions/bulkhead_rejected_exception.dart';
import '../policies/circuit_breaker_policy.dart';

// ============================================================================
// ResilienceEvent — sealed base
// ============================================================================

/// Immutable base class for all resilience lifecycle events.
///
/// Every event carries a [timestamp] (captured at construction) and a [source]
/// label that identifies the policy that emitted it. Use
/// `ResilienceEventHub` to subscribe and `ResilienceEventHub.emit` to publish.
///
/// ## Event hierarchy
///
/// The event hierarchy is **sealed** — no external subclasses are permitted,
/// which enables exhaustive `switch` expressions:
///
/// ```dart
/// hub.onAny((event) => switch (event) {
///   RetryEvent e            => print('Retry ${e.attemptNumber}/${e.maxAttempts}'),
///   CircuitOpenEvent e      => print('Circuit ${e.circuitName} opened'),
///   CircuitCloseEvent e     => print('Circuit ${e.circuitName} closed'),
///   TimeoutEvent e          => print('Timed out after ${e.timeout.inMilliseconds}ms'),
///   FallbackEvent e         => print('Fallback triggered: ${e.exception}'),
///   BulkheadRejectedEvent e => print('Bulkhead rejected: ${e.reason}'),
///   HedgingEvent e          => print('Hedge attempt #${e.attemptNumber} fired'),
///   HedgingOutcomeEvent e   => print('Hedging winner: attempt #${e.winningAttempt}'),
/// });
/// ```
sealed class ResilienceEvent {
  ResilienceEvent({this.source = ''}) : timestamp = DateTime.now().toUtc();

  /// UTC timestamp captured when this event was constructed.
  final DateTime timestamp;

  /// Human-readable label identifying the emitting policy.
  ///
  /// Typically the policy's `runtimeType` name or the circuit name.
  final String source;
}

// ============================================================================
// RetryEvent
// ============================================================================

/// Emitted by `RetryResiliencePolicy` just before backing off and retrying.
///
/// [attemptNumber] is 1-based and identifies the attempt that **just failed**.
/// The event is not emitted on the final failure that exhausts all retries —
/// only on attempts where a follow-up retry will occur.
///
/// ```dart
/// hub.on<RetryEvent>((e) {
///   metrics.increment('retry.count',
///       tags: {'attempt': e.attemptNumber.toString()});
/// });
/// ```
final class RetryEvent extends ResilienceEvent {
  /// Creates a [RetryEvent].
  ///
  /// [attemptNumber] — 1-based index of the attempt that just failed.
  /// [maxAttempts]   — total attempts allowed (`maxRetries + 1`), or `null`
  ///                   when the policy runs in infinite-retry mode.
  /// [delay]         — back-off delay before the next attempt.
  /// [exception]     — the error that triggered the retry, or `null` when
  ///                   the retry was triggered by a result predicate.
  /// [stackTrace]    — stack trace for [exception], when available.
  RetryEvent({
    required this.attemptNumber,
    required this.delay,
    this.maxAttempts,
    this.exception,
    this.stackTrace,
    super.source,
  });

  /// 1-based index of the attempt that just failed.
  ///
  /// A value of `1` means the initial call failed and a retry will fire.
  /// A value of `maxAttempts - 1` means the penultimate attempt failed.
  final int attemptNumber;

  /// Total attempts allowed = `maxRetries + 1`, or `null` for infinite-retry
  /// mode (`retryForever: true`).
  final int? maxAttempts;

  /// Back-off delay that will be applied before the next attempt.
  final Duration delay;

  /// The error that triggered the retry, or `null` for result-based retries.
  final Object? exception;

  /// Stack trace associated with [exception], when available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'RetryEvent('
      'attempt=$attemptNumber/${maxAttempts ?? '∞'}, '
      'delay=${delay.inMilliseconds}ms, '
      'source=$source, '
      'exception=${exception?.runtimeType})';
}

// ============================================================================
// CircuitOpenEvent
// ============================================================================

/// Emitted by `CircuitBreakerResiliencePolicy` when the circuit transitions
/// **to the open state** (Closed→Open or HalfOpen→Open).
///
/// ```dart
/// hub.on<CircuitOpenEvent>((e) {
///   alerting.fire('circuit_open',
///       circuit: e.circuitName, failures: e.consecutiveFailures);
/// });
/// ```
final class CircuitOpenEvent extends ResilienceEvent {
  /// Creates a [CircuitOpenEvent].
  ///
  /// [circuitName]          — logical name of the circuit.
  /// [previousState]        — state before opening (closed or halfOpen).
  /// [consecutiveFailures]  — failures that triggered the transition.
  CircuitOpenEvent({
    required this.circuitName,
    required this.previousState,
    required this.consecutiveFailures,
    super.source,
  });

  /// Logical name of the circuit, as configured in `CircuitBreakerResiliencePolicy`.
  final String circuitName;

  /// The state the circuit was in before opening.
  ///
  /// Either [CircuitState.closed] (normal open) or [CircuitState.halfOpen]
  /// (probe failure re-opens).
  final CircuitState previousState;

  /// Number of consecutive failures that triggered this transition.
  ///
  /// For Closed→Open this equals `failureThreshold`. For HalfOpen→Open
  /// this is `1` (the probe failure).
  final int consecutiveFailures;

  @override
  String toString() => 'CircuitOpenEvent('
      'circuit=$circuitName, '
      'from=$previousState, '
      'failures=$consecutiveFailures, '
      'source=$source)';
}

// ============================================================================
// CircuitCloseEvent
// ============================================================================

/// Emitted by `CircuitBreakerResiliencePolicy` when the circuit transitions
/// **to the closed state** (HalfOpen→Closed after a successful probe).
///
/// ```dart
/// hub.on<CircuitCloseEvent>((e) {
///   log.info('Circuit ${e.circuitName} recovered');
/// });
/// ```
final class CircuitCloseEvent extends ResilienceEvent {
  /// Creates a [CircuitCloseEvent].
  ///
  /// [circuitName]   — logical name of the circuit.
  /// [previousState] — state before closing (typically [CircuitState.halfOpen]).
  CircuitCloseEvent({
    required this.circuitName,
    required this.previousState,
    super.source,
  });

  /// Logical name of the circuit.
  final String circuitName;

  /// The state the circuit was in before closing.
  ///
  /// Typically [CircuitState.halfOpen] when a successful probe closes the
  /// circuit, or [CircuitState.open] for a hard manual [reset()].
  final CircuitState previousState;

  @override
  String toString() => 'CircuitCloseEvent('
      'circuit=$circuitName, '
      'from=$previousState, '
      'source=$source)';
}

// ============================================================================
// TimeoutEvent
// ============================================================================

/// Emitted by `TimeoutResiliencePolicy` when an action exceeds its time budget.
///
/// ```dart
/// hub.on<TimeoutEvent>((e) {
///   metrics.increment('timeout', tags: {'budget': '${e.timeout.inMilliseconds}ms'});
/// });
/// ```
final class TimeoutEvent extends ResilienceEvent {
  /// Creates a [TimeoutEvent].
  ///
  /// [timeout]   — configured time budget that was exceeded.
  /// [exception] — the `HttpTimeoutException` that was thrown, when available.
  TimeoutEvent({
    required this.timeout,
    this.exception,
    super.source,
  });

  /// The configured time budget that was exceeded.
  final Duration timeout;

  /// The exception thrown by the policy (`HttpTimeoutException`), when
  /// available.
  final Object? exception;

  @override
  String toString() => 'TimeoutEvent('
      'timeout=${timeout.inMilliseconds}ms, '
      'source=$source, '
      'exception=${exception?.runtimeType})';
}

// ============================================================================
// FallbackEvent
// ============================================================================

/// Emitted by `FallbackResiliencePolicy` just before the fallback action runs.
///
/// [exception] is `null` when the fallback was triggered by a result predicate
/// or `OutcomeClassifier` rather than a thrown exception.
///
/// ```dart
/// hub.on<FallbackEvent>((e) {
///   log.warning(
///     'Fallback triggered by ${e.exception?.runtimeType ?? "result classifier"}',
///   );
/// });
/// ```
final class FallbackEvent extends ResilienceEvent {
  /// Creates a [FallbackEvent].
  ///
  /// [exception]   — the error that triggered the fallback, or `null`.
  /// [stackTrace]  — stack trace for [exception], when available.
  FallbackEvent({
    this.exception,
    this.stackTrace,
    super.source,
  });

  /// The exception that triggered the fallback.
  ///
  /// `null` when the fallback was triggered by a result predicate or classifier
  /// rather than a thrown error.
  final Object? exception;

  /// Stack trace associated with [exception], when available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'FallbackEvent('
      'source=$source, '
      'exception=${exception?.runtimeType})';
}

// ============================================================================
// BulkheadRejectedEvent
// ============================================================================

/// Emitted by `BulkheadResiliencePolicy` and `BulkheadIsolationResiliencePolicy`
/// when a request is rejected because all concurrency slots and queue positions
/// are occupied, or when a queued request exceeds `queueTimeout`.
///
/// ```dart
/// hub.on<BulkheadRejectedEvent>((e) {
///   metrics.increment('bulkhead.rejected',
///       tags: {'reason': e.reason?.name ?? 'overflow'});
/// });
/// ```
final class BulkheadRejectedEvent extends ResilienceEvent {
  /// Creates a [BulkheadRejectedEvent].
  ///
  /// [maxConcurrency] — the configured concurrency cap.
  /// [maxQueueDepth]  — the configured queue depth.
  /// [reason]         — rejection reason; `null` for `BulkheadResiliencePolicy`,
  ///                    [BulkheadRejectionReason.queueFull] or
  ///                    [BulkheadRejectionReason.queueTimeout] for
  ///                    `BulkheadIsolationResiliencePolicy`.
  BulkheadRejectedEvent({
    required this.maxConcurrency,
    required this.maxQueueDepth,
    this.reason,
    super.source,
  });

  /// The configured maximum concurrent executions.
  final int maxConcurrency;

  /// The configured maximum queue depth.
  final int maxQueueDepth;

  /// Specific rejection reason, when provided by the policy.
  ///
  /// * `null` — emitted by `BulkheadResiliencePolicy` (legacy semaphore).
  /// * [BulkheadRejectionReason.queueFull] — queue capacity exhausted.
  /// * [BulkheadRejectionReason.queueTimeout] — waited too long in queue.
  final BulkheadRejectionReason? reason;

  @override
  String toString() => 'BulkheadRejectedEvent('
      'maxConcurrency=$maxConcurrency, '
      'maxQueueDepth=$maxQueueDepth, '
      'reason=$reason, '
      'source=$source)';
}

// ============================================================================
// HedgingEvent
// ============================================================================

/// Emitted by `HedgingHandler` just before each **additional speculative
/// concurrent request** is fired.
///
/// The first attempt (attempt 1) is fired silently without emitting an event.
/// [HedgingEvent] is emitted for attempt 2, 3, … up to
/// `HedgingPolicy.maxHedgedAttempts + 1`.
///
/// ```dart
/// hub.on<HedgingEvent>((e) {
///   metrics.increment('http.hedge.fired',
///       tags: {'attempt': e.attemptNumber.toString()});
/// });
/// ```
final class HedgingEvent extends ResilienceEvent {
  /// Creates a [HedgingEvent].
  ///
  /// [attemptNumber] — 1-based index of the speculative attempt being fired
  ///                   (always >= 2; attempt 1 is the initial request).
  /// [hedgeAfter]    — the `HedgingPolicy.hedgeAfter` duration that elapsed
  ///                   before this hedge was triggered.
  HedgingEvent({
    required this.attemptNumber,
    required this.hedgeAfter,
    super.source,
  });

  /// 1-based index of the speculative attempt that was just fired.
  ///
  /// A value of `2` means the first extra concurrent request was launched.
  final int attemptNumber;

  /// The `HedgingPolicy.hedgeAfter` duration that elapsed before this hedge.
  final Duration hedgeAfter;

  @override
  String toString() => 'HedgingEvent('
      'attempt=$attemptNumber, '
      'hedgeAfter=${hedgeAfter.inMilliseconds}ms, '
      'source=$source)';
}

// ============================================================================
// HedgingOutcomeEvent
// ============================================================================

/// Emitted by `HedgingHandler` when a **winning** response is accepted from
/// one of the concurrent speculative attempts.
///
/// A "winning" response satisfies `HedgingPolicy.shouldHedge == false` (or is
/// a 2xx when no predicate is configured).
///
/// ```dart
/// hub.on<HedgingOutcomeEvent>((e) {
///   metrics.histogram('http.hedge.winning_attempt', e.winningAttempt,
///       tags: {'total': e.totalAttempts.toString()});
/// });
/// ```
final class HedgingOutcomeEvent extends ResilienceEvent {
  /// Creates a [HedgingOutcomeEvent].
  ///
  /// [winningAttempt] — 1-based index of the attempt that supplied the
  ///                    accepted response.
  /// [totalAttempts]  — how many concurrent requests were in flight when the
  ///                    winner was found.
  HedgingOutcomeEvent({
    required this.winningAttempt,
    required this.totalAttempts,
    super.source,
  });

  /// 1-based index of the attempt that delivered the winning response.
  ///
  /// A value of `1` means the original request won (the fastest path).
  final int winningAttempt;

  /// Total number of concurrent in-flight requests at the time the winner was
  /// found, including the original request.
  final int totalAttempts;

  @override
  String toString() => 'HedgingOutcomeEvent('
      'winningAttempt=$winningAttempt, '
      'totalAttempts=$totalAttempts, '
      'source=$source)';
}
