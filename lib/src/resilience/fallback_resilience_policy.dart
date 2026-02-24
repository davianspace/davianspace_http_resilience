import '../core/http_response.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import 'outcome_classification.dart';
import 'resilience_policy.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Typedefs
// ═══════════════════════════════════════════════════════════════════════════

/// Async action to execute as a fallback when the primary action fails.
///
/// [exception] is the error that triggered the fallback (or `null` when the
/// trigger was a result classified as failure by [OutcomeClassifier]).
/// [stackTrace] is the associated stack trace, when available.
///
/// The return type is erased to [Object?] because [FallbackResiliencePolicy]
/// operates on generic results via [ResiliencePolicy.execute].  In practice
/// the returned value **must** be assignable to `T` in the surrounding
/// [`execute`] call — the caller is responsible for type safety.
///
/// ### Example
/// ```dart
/// FallbackAction fallback = (ex, st) async =>
///     HttpResponse(statusCode: 200, body: 'cached'.codeUnits);
/// ```
typedef FallbackAction = Future<Object?> Function(
  Object? exception,
  StackTrace? stackTrace,
);

/// Predicate that decides whether the fallback should fire for a given
/// [exception].
///
/// When omitted from [FallbackResiliencePolicy] all exceptions are handled.
/// Return `false` to let the exception propagate.
typedef FallbackExceptionPredicate = bool Function(Object exception);

/// Predicate that decides whether the fallback should fire for a given
/// [result] (successful response classified as a failure).
///
/// Return `true` to trigger the fallback on this result value.
typedef FallbackResultPredicate = bool Function(Object? result);

/// Side-effect callback invoked *before* the fallback action runs.
///
/// Use for logging, metrics, or alerting.  Must not throw.
///
/// ```dart
/// onFallback: (ex, st) => log.warning('Fallback triggered: $ex'),
/// ```
typedef FallbackCallback = void Function(
  Object? exception,
  StackTrace? stackTrace,
);

// ═══════════════════════════════════════════════════════════════════════════
//  FallbackResiliencePolicy
// ═══════════════════════════════════════════════════════════════════════════

/// A [ResiliencePolicy] that executes an alternative [fallbackAction] when
/// the primary action fails (throws an exception or returns an unacceptable
/// result).
///
/// ## Basic usage — catch all exceptions
///
/// ```dart
/// final policy = FallbackResiliencePolicy(
///   fallbackAction: (ex, st) async =>
///       HttpResponse(statusCode: 200, body: 'cached data'.codeUnits),
/// );
///
/// final response = await policy.execute(() => httpClient.get(uri));
/// ```
///
/// ## Filter by exception type
///
/// ```dart
/// final policy = FallbackResiliencePolicy(
///   fallbackAction: (ex, st) async => HttpResponse.ok(),
///   shouldHandle: (ex) => ex is SocketException || ex is TimeoutException,
/// );
/// ```
///
/// ## Classifier-driven result fallback
///
/// Trigger the fallback not only on exceptions but also when the primary
/// result is classified as a failure (e.g., 5xx HTTP responses):
///
/// ```dart
/// final policy = FallbackResiliencePolicy(
///   classifier: const HttpOutcomeClassifier(),
///   fallbackAction: (ex, st) async =>
///       HttpResponse(statusCode: 200, body: cachedBytes),
///   onFallback: (ex, st) => metrics.increment('fallback.triggered'),
/// );
/// ```
///
/// ## Custom result predicate
///
/// For non-HTTP result types or fine-grained result inspection:
///
/// ```dart
/// final policy = FallbackResiliencePolicy(
///   shouldHandleResult: (result) =>
///       result is HttpResponse && result.statusCode == 503,
///   fallbackAction: (_, __) async => HttpResponse.ok(body: fallbackBody),
/// );
/// ```
///
/// ## Composition
///
/// [FallbackResiliencePolicy] composes naturally with other policies.  Place
/// it **outermost** so it catches exhausted retries and open circuits:
///
/// ```dart
/// final pipeline = Policy.wrap([
///   Policy.fallback(
///     fallbackAction: (_, __) async => HttpResponse.cached('cached'),
///   ),
///   Policy.timeout(const Duration(seconds: 10)),
///   Policy.retry(maxRetries: 3),
/// ]);
/// ```
///
/// ## Statelessness
///
/// [FallbackResiliencePolicy] is **stateless** — it holds only configuration,
/// never per-request mutable state.  Instances are safe to share and reuse
/// concurrently.
final class FallbackResiliencePolicy extends ResiliencePolicy {
  /// Creates a [FallbackResiliencePolicy].
  ///
  /// [fallbackAction]    — executed when the primary action fails or returns
  ///                       an unacceptable result.  **Must** return a value
  ///                       assignable to the `T` used at the call-site.
  /// [shouldHandle]      — optional exception filter; all exceptions handled
  ///                       when `null`.  Return `false` to propagate.
  /// [shouldHandleResult]— optional result filter; triggers the fallback when
  ///                       the primary action *succeeds* but returns an
  ///                       unacceptable value.  Takes precedence over
  ///                       [classifier] for result classification.
  /// [classifier]        — optional [OutcomeClassifier]; used to decide
  ///                       whether a successful result (e.g. an [HttpResponse])
  ///                       warrants a fallback.  Ignored when [shouldHandleResult]
  ///                       is non-null.
  /// [onFallback]        — optional side-effect callback invoked just before
  ///                       the fallback action runs.  Useful for logging or
  ///                       metrics.  Must not throw.
  const FallbackResiliencePolicy({
    required this.fallbackAction,
    this.shouldHandle,
    this.shouldHandleResult,
    this.classifier,
    this.onFallback,
    this.eventHub,
  });

  // --------------------------------------------------------------------------
  // Configuration
  // --------------------------------------------------------------------------

  /// The action to execute when the primary fails.
  final FallbackAction fallbackAction;

  /// Optional exception filter.
  ///
  /// When `null` all exceptions trigger the fallback.  When non-null the
  /// fallback fires only when this predicate returns `true`; otherwise the
  /// exception is re-thrown.
  final FallbackExceptionPredicate? shouldHandle;

  /// Optional result-based trigger predicate.
  ///
  /// When non-null the fallback fires when the primary action *succeeds* but
  /// this predicate returns `true`.  Takes precedence over [classifier].
  final FallbackResultPredicate? shouldHandleResult;

  /// Optional [OutcomeClassifier] used to trigger the fallback on classified
  /// [HttpResponse] results.
  ///
  /// The fallback fires when
  /// [OutcomeClassifier.classifyResponse] returns a non-success classification.
  /// Ignored when [shouldHandleResult] is non-null.
  final OutcomeClassifier? classifier;

  /// Optional side-effect callback fired just before [fallbackAction].
  ///
  /// Use for logging, metrics, or alerting.  Must not throw.
  final FallbackCallback? onFallback;

  /// Optional [ResilienceEventHub] that receives a `FallbackEvent` just before
  /// the fallback action runs.
  ///
  /// Events are dispatched via `scheduleMicrotask` and never block execution.
  final ResilienceEventHub? eventHub;

  // --------------------------------------------------------------------------
  // Execution
  // --------------------------------------------------------------------------

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    try {
      final result = await action();

      // ── Result-based fallback ─────────────────────────────────────────────

      // 1. Check shouldHandleResult predicate first (higher priority).
      //    When the predicate is non-null it acts as the sole result gate;
      //    if it returns false the classifier is NOT consulted.
      final resultPredicate = shouldHandleResult;
      if (resultPredicate != null) {
        if (resultPredicate(result)) {
          onFallback?.call(null, null);
          eventHub?.emit(FallbackEvent(source: 'FallbackResiliencePolicy'));
          return await fallbackAction(null, null) as T;
        }
        // Predicate present but returned false — done, no fallback.
        return result;
      }

      // 2. Check OutcomeClassifier for HttpResponse results.
      //    Only reached when shouldHandleResult is absent.
      final cl = classifier;
      if (cl != null && result is HttpResponse) {
        if (cl.classifyResponse(result).isFailure) {
          onFallback?.call(null, null);
          eventHub?.emit(FallbackEvent(source: 'FallbackResiliencePolicy'));
          return await fallbackAction(null, null) as T;
        }
      }

      return result;
    } catch (e, st) {
      final handle = shouldHandle;
      if (handle != null && !handle(e)) {
        // Non-matching exception — propagate immediately.
        Error.throwWithStackTrace(e, st);
      }

      onFallback?.call(e, st);
      eventHub?.emit(
        FallbackEvent(
          exception: e,
          stackTrace: st,
          source: 'FallbackResiliencePolicy',
        ),
      );
      return await fallbackAction(e, st) as T;
    }
  }

  @override
  String toString() {
    final parts = <String>[];
    if (shouldHandle != null) parts.add('filtered');
    if (classifier != null) parts.add('classifier=${classifier.runtimeType}');
    if (shouldHandleResult != null) parts.add('resultFiltered');
    return 'FallbackResiliencePolicy(${parts.isEmpty ? '' : parts.join(', ')})';
  }
}
