import '../core/http_context.dart';
import '../core/http_response.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';

/// Determines whether an already-received [HttpResponse] is "good enough" to
/// be returned as the hedging winner, or whether we should keep waiting for a
/// faster concurrent attempt.
///
/// Return `true` to **continue hedging** (this response is NOT a winner).
/// Return `false` to **accept this response** as the hedging winner.
///
/// When `null` is passed to [HedgingPolicy.shouldHedge], the default
/// behaviour is to accept any 2xx response as a winner.
typedef HedgePredicate = bool Function(HttpResponse response, HttpContext ctx);

/// Immutable configuration for the hedging policy.
///
/// **Hedging** (also known as *speculative execution*) is a latency-tail
/// reduction technique: the first request is fired immediately; if it has not
/// produced an acceptable response within [hedgeAfter], a second identical
/// request is fired concurrently. This continues until either a "winning"
/// response is received or [maxHedgedAttempts] additional concurrent requests
/// have been launched. The first acceptable response wins; all remaining
/// in-flight requests are abandoned.
///
/// Unlike retries, hedging does **not** wait for the first attempt to fail —
/// it sends speculative duplicates proactively to trade off extra server load
/// for lower perceived latency at the p95+ percentiles.
///
/// ## Placement in the pipeline
///
/// Place `HedgingHandler` **after** `LoggingHandler` and **before** timeout /
/// bulkhead policies. It should not wrap a `RetryHandler` or a circuit
/// breaker because those add their own latency semantics:
///
/// ```
/// LoggingHandler ──► HedgingHandler ──► TimeoutHandler ──► TerminalHandler
/// ```
///
/// ## Example
///
/// ```dart
/// // Accept any 2xx; hedge after 300 ms, up to 2 extra concurrent attempts.
/// final policy = HedgingPolicy(
///   hedgeAfter: Duration(milliseconds: 300),
///   maxHedgedAttempts: 2,
/// );
///
/// // Custom predicate: hedge if the response is not 200 OK.
/// final strictPolicy = HedgingPolicy(
///   hedgeAfter: Duration(milliseconds: 200),
///   shouldHedge: (response, _) => response.statusCode != 200,
///   onHedge: (attempt, ctx) =>
///       print('Fired hedge attempt #$attempt for ${ctx.request.uri}'),
/// );
/// ```
final class HedgingPolicy {
  /// Creates a [HedgingPolicy].
  ///
  /// [hedgeAfter]        — how long to wait for the previous attempt before
  ///                       firing the next speculative request. Defaults to
  ///                       200 ms.
  /// [maxHedgedAttempts] — how many **additional** concurrent requests to fire
  ///                       on top of the original. Must be >= 1. Defaults to
  ///                       `1`, which means at most 2 concurrent requests.
  /// [shouldHedge]       — optional predicate. Returning `true` means "this
  ///                       response is not good enough; keep waiting for a
  ///                       better concurrent attempt". When `null`, any 2xx
  ///                       response is treated as a winner.
  /// [onHedge]           — optional callback invoked each time a new
  ///                       speculative request is fired. Useful for metrics.
  /// [eventHub]          — optional [ResilienceEventHub] that receives
  ///                       [HedgingEvent] and [HedgingOutcomeEvent] instances.
  const HedgingPolicy({
    this.hedgeAfter = const Duration(milliseconds: 200),
    this.maxHedgedAttempts = 1,
    this.shouldHedge,
    this.onHedge,
    this.eventHub,
  }) : assert(maxHedgedAttempts >= 1, 'maxHedgedAttempts must be >= 1');

  /// How long to wait for the current in-flight attempt before launching the
  /// next speculative request.
  ///
  /// Setting this too low increases backend load; too high negates the benefit
  /// of hedging. A typical value is the p95-p99 latency of the target service.
  ///
  /// Defaults to 200 ms.
  final Duration hedgeAfter;

  /// Number of **additional** concurrent requests that may be launched on top
  /// of the original.
  ///
  /// The total number of concurrent requests is `maxHedgedAttempts + 1`.
  /// Must be `>= 1`. Defaults to `1` (= 2 concurrent requests at most).
  final int maxHedgedAttempts;

  /// Optional predicate that determines whether a received response is a
  /// "hedging winner".
  ///
  /// Return `true`  → this response is NOT acceptable; keep waiting for a
  ///                   faster or different concurrent attempt.
  /// Return `false` → accept this response as the winner immediately.
  ///
  /// When `null`, [HttpResponse.isSuccess] (2xx status) is used.
  final HedgePredicate? shouldHedge;

  /// Optional callback invoked synchronously just before each **extra**
  /// speculative request is fired.
  ///
  /// `attemptNumber` is 2-based (the first hedge is attempt 2, second is 3…).
  ///
  /// Use this for metrics, alerting, or structured logging:
  ///
  /// ```dart
  /// onHedge: (attempt, ctx) =>
  ///   metrics.increment('http.hedge', tags: {'attempt': '$attempt'}),
  /// ```
  final void Function(int attemptNumber, HttpContext ctx)? onHedge;

  /// Optional [ResilienceEventHub] that receives hedging lifecycle events.
  ///
  /// `HedgingEvent` is emitted before each speculative request is fired.
  /// `HedgingOutcomeEvent` is emitted when a winning response is found.
  final ResilienceEventHub? eventHub;

  @override
  String toString() => 'HedgingPolicy('
      'hedgeAfter=${hedgeAfter.inMilliseconds}ms, '
      'maxHedgedAttempts=$maxHedgedAttempts)';
}
