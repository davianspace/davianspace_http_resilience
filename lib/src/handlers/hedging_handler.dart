import 'dart:async';

import '../core/http_context.dart';
import '../core/http_response.dart';
import '../exceptions/hedging_exception.dart';
import '../observability/resilience_event.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/hedging_policy.dart';

/// A [DelegatingHandler] that implements the **hedging** (speculative
/// execution) pattern to reduce tail latency.
///
/// ## How it works
///
/// 1. The first request is dispatched immediately.
/// 2. After [HedgingPolicy.hedgeAfter] elapses without an acceptable
///    response, a second identical request is fired concurrently.
/// 3. This continues until a winning response is received, or until
///    `HedgingPolicy.maxHedgedAttempts + 1` concurrent requests are in flight
///    and all of them have finished.
/// 4. The first "winning" response is returned; all other in-flight requests
///    are abandoned (their results are silently discarded).
/// 5. If no attempt produces a winning response, the last non-winning response
///    is returned. If **all** attempts throw (network-level errors), a
///    [HedgingException] is thrown containing the last cause.
///
/// ## What counts as a winner
///
/// By default, any 2xx response (`HttpResponse.isSuccess`) is a winner.
/// Supply [HedgingPolicy.shouldHedge] to customise: returning `true` from the
/// predicate means "this is NOT good enough, keep hedging".
///
/// ## Compatibility notes
///
/// * **Idempotency** — hedging fires identical repeated requests. Only use it
///   for idempotent operations (GET, HEAD, PUT, DELETE with idempotent
///   semantics). Never hedge POST or PATCH without explicit idempotency
///   guarantees.
/// * **Streaming** — each concurrent request creates an independent HTTP
///   connection; losing attempts are abandoned after the winner is accepted.
///   Opened connections will be reclaimed by the underlying `http.Client`.
/// * **Retry** — do **not** wrap a `RetryHandler` inside `HedgingHandler`.
///   Use them at the same pipeline level or separately.
/// * **Cancellation** — if the outer `HttpContext.cancellationToken` is
///   cancelled before a winner is found, a `CancellationException` propagates
///   immediately; any already-fired speculative requests are abandoned.
///
/// ## Example
///
/// ```dart
/// final client = HttpClientBuilder()
///     .withBaseUri(Uri.parse('https://api.example.com'))
///     .withLogging()
///     .withHedging(HedgingPolicy(
///       hedgeAfter: Duration(milliseconds: 300),
///       maxHedgedAttempts: 2,
///     ))
///     .build();
/// ```
final class HedgingHandler extends DelegatingHandler {
  /// Creates a [HedgingHandler] driven by the given policy.
  HedgingHandler(this._policy);

  final HedgingPolicy _policy;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    final totalAttempts = _policy.maxHedgedAttempts + 1;

    // One shared Completer drives the result. The first "winning" attempt
    // calls completer.complete(); the last finished attempt resolves it if no
    // winner was found.
    final completer = Completer<HttpResponse>();

    // ---------------------------------------------------------------------------
    // Mutable counters/state — safe because Dart's event loop is single-threaded.
    // All closures below run on the same isolate (no concurrent writes).
    // ---------------------------------------------------------------------------
    var firedCount = 0; // how many attempts have been launched
    var doneCount = 0; // how many have finished (success, non-winner, or error)
    var allFired = false; // set to true after the last attempt is launched

    HttpResponse? bestNonWinner; // last non-winning (non-2xx) response
    Object? lastError; // last exception from a failed attempt
    StackTrace? lastStackTrace;

    // -------------------------------------------------------------------------
    // tryResolve — called from every completion path.
    //
    // Resolves the completer with the best available result once all in-flight
    // attempts have finished AND no winner has been found yet.
    // -------------------------------------------------------------------------
    void tryResolve() {
      if (completer.isCompleted) return;
      if (!allFired || doneCount < firedCount) return;

      // All attempts have finished without a winner.
      if (bestNonWinner != null) {
        // Return the last non-winning HTTP response rather than throwing — the
        // caller can inspect statusCode and decide what to do.
        completer.complete(bestNonWinner);
      } else {
        // Every attempt threw a network-level exception.
        completer.completeError(
          HedgingException(
            attemptsMade: firedCount,
            cause: lastError,
            stackTrace: lastStackTrace,
          ),
          lastStackTrace,
        );
      }
    }

    // -------------------------------------------------------------------------
    // fireAttempt — launches attempt [attemptNumber] (1-based) concurrently.
    //
    // Each attempt beyond the first gets a fresh HttpContext so that mutable
    // state (retryCount, properties, stopwatch) does not bleed between siblings.
    // All contexts share the same cancellationToken so that an external cancel
    // propagates to all in-flight requests.
    // -------------------------------------------------------------------------
    void fireAttempt(int attemptNumber) {
      final hedgeCtx = attemptNumber == 1
          ? context
          : HttpContext(
              request: context.request,
              cancellationToken: context.cancellationToken,
              properties: Map<String, Object?>.of(context.properties),
            );

      firedCount++;

      innerHandler.send(hedgeCtx).then(
        (response) {
          doneCount++;

          if (!completer.isCompleted && _isWinner(response, hedgeCtx)) {
            // This response wins — emit observability event and complete.
            _policy.eventHub?.emit(
              HedgingOutcomeEvent(
                winningAttempt: attemptNumber,
                totalAttempts: firedCount,
                source: 'HedgingHandler',
              ),
            );
            completer.complete(response);
          } else {
            // Non-winning response — keep as fallback.
            bestNonWinner ??= response;
            tryResolve();
          }
        },
        // ignore: avoid_types_on_closure_parameters
        onError: (Object err, StackTrace st) {
          doneCount++;
          lastError = err;
          lastStackTrace = st;
          tryResolve();
        },
      );
    }

    // -------------------------------------------------------------------------
    // Fire initial attempt immediately.
    // -------------------------------------------------------------------------
    fireAttempt(1);

    // -------------------------------------------------------------------------
    // Fire subsequent speculative attempts with delays between them.
    // -------------------------------------------------------------------------
    for (var i = 2; i <= totalAttempts; i++) {
      // Wait for hedgeAfter OR until the completer is already resolved
      // (winner found by an earlier attempt — no need to fire more).
      await Future.any<void>([
        Future<void>.delayed(_policy.hedgeAfter),
        // Attach onError: ignore so that a completer error doesn't become an
        // unhandled rejection during the race.
        completer.future.then((_) {}, onError: (_) {}),
      ]);

      if (completer.isCompleted) break;

      // Emit HedgingEvent and call the user-supplied callback.
      _policy.eventHub?.emit(
        HedgingEvent(
          attemptNumber: i,
          hedgeAfter: _policy.hedgeAfter,
          source: 'HedgingHandler',
        ),
      );
      _policy.onHedge?.call(i, context);

      // Re-check in case a rapid response arrived while we were awaiting.
      if (completer.isCompleted) break;

      fireAttempt(i);
    }

    // Mark that we've launched all the attempts we intend to.
    allFired = true;

    // Trigger the "all done" resolution in case every attempt already finished
    // before we set allFired (extremely fast inner handlers in tests).
    tryResolve();

    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // _isWinner — returns true when [response] is acceptable as the final result.
  // ---------------------------------------------------------------------------
  bool _isWinner(HttpResponse response, HttpContext ctx) {
    final predicate = _policy.shouldHedge;
    if (predicate != null) {
      // shouldHedge returning true = "not good enough, keep hedging"
      return !predicate(response, ctx);
    }
    return response.isSuccess;
  }
}
