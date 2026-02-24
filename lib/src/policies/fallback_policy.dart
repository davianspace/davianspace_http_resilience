import '../core/http_context.dart';
import '../core/http_response.dart';
import '../resilience/outcome_classification.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Typedefs
// ═══════════════════════════════════════════════════════════════════════════

/// Async action to execute as a fallback inside the handler pipeline.
///
/// [context]   — the original [HttpContext] for the request.
/// [exception] — the exception that caused the fallback to fire, or `null`
///               when the trigger was a response classified as failure.
/// [stackTrace]— associated stack trace, when available.
///
/// ### Example
/// ```dart
/// FallbackHttpAction action = (ctx, err, st) async =>
///     HttpResponse.cached('offline data');
/// ```
typedef FallbackHttpAction = Future<HttpResponse> Function(
  HttpContext context,
  Object? exception,
  StackTrace? stackTrace,
);

/// Predicate that controls which outcomes trigger the fallback inside the
/// handler pipeline.
///
/// [response]  — the [HttpResponse] when the pipeline succeeded, else `null`.
/// [exception] — the caught exception, or `null` for response-based triggers.
/// [context]   — the current [HttpContext].
///
/// Return `true` to activate the fallback; `false` to let the outcome pass.
typedef FallbackHttpPredicate = bool Function(
  HttpResponse? response,
  Object? exception,
  HttpContext context,
);

/// Side-effect callback invoked *before* the fallback action runs in the
/// handler pipeline.
///
/// Useful for logging, metrics, or alerting.  Must not throw.
///
/// ```dart
/// onFallback: (ctx, err, st) => log.warning('fallback for ${ctx.request}'),
/// ```
typedef FallbackHttpCallback = void Function(
  HttpContext context,
  Object? exception,
  StackTrace? stackTrace,
);

// ═══════════════════════════════════════════════════════════════════════════
//  FallbackPolicy
// ═══════════════════════════════════════════════════════════════════════════

/// Configuration for a fallback step in the `HttpClientBuilder` handler
/// pipeline.
///
/// [FallbackPolicy] is a **value object** — it holds only configuration and
/// is immutable.  It is consumed by `FallbackHandler` which performs the
/// actual interception.
///
/// ## Basic usage — catch all exceptions
///
/// ```dart
/// final policy = FallbackPolicy(
///   fallbackAction: (ctx, err, st) async =>
///       HttpResponse.cached('offline data'),
/// );
///
/// final client = HttpClientFactory.createBuilder()
///     .withFallback(policy)
///     .build();
/// ```
///
/// ## Filter by exception type
///
/// ```dart
/// final policy = FallbackPolicy(
///   fallbackAction: (ctx, err, st) async => HttpResponse.ok(),
///   shouldHandle: (response, ex, ctx) => ex is SocketException,
/// );
/// ```
///
/// ## Classifier-driven response fallback
///
/// Trigger the fallback when the inner pipeline returns a 5xx response:
///
/// ```dart
/// final policy = FallbackPolicy(
///   classifier: const HttpOutcomeClassifier(),
///   fallbackAction: (ctx, err, st) async =>
///       HttpResponse(statusCode: 200, body: cachedBytes),
///   onFallback: (ctx, err, st) => metrics.increment('fallback'),
/// );
/// ```
///
/// ## Custom response predicate
///
/// ```dart
/// final policy = FallbackPolicy(
///   shouldHandle: (response, ex, ctx) =>
///       ex != null || (response?.statusCode ?? 200) >= 500,
///   fallbackAction: (ctx, _, __) async => cachedResponses[ctx.request.uri],
/// );
/// ```
final class FallbackPolicy {
  /// Creates a [FallbackPolicy].
  ///
  /// [fallbackAction]  — called when the primary pipeline fails or returns an
  ///                     unacceptable response.  Must return an [HttpResponse].
  /// [shouldHandle]    — optional predicate controlling which exceptions or
  ///                     responses trigger the fallback.  All exceptions are
  ///                     handled when `null`.  Passing a non-null predicate
  ///                     **also** controls response-based fallback; when both
  ///                     [shouldHandle] and [classifier] are non-null,
  ///                     [shouldHandle] takes precedence at the response level.
  /// [classifier]      — optional [OutcomeClassifier]; triggers the fallback
  ///                     when a successful [HttpResponse] is classified as
  ///                     failure.  Applies only when [shouldHandle] returns
  ///                     `true` or is `null` for the response.
  /// [onFallback]      — optional side-effect callback fired before
  ///                     [fallbackAction].  Must not throw.
  const FallbackPolicy({
    required this.fallbackAction,
    this.shouldHandle,
    this.classifier,
    this.onFallback,
  });

  /// The action that produces the fallback [HttpResponse].
  final FallbackHttpAction fallbackAction;

  /// Optional predicate to filter which outcomes trigger the fallback.
  ///
  /// When `null` the fallback fires for every exception.  For
  /// response-based triggers the [classifier] check applies regardless.
  final FallbackHttpPredicate? shouldHandle;

  /// Optional [OutcomeClassifier] used to trigger the fallback on failed
  /// [HttpResponse] results (e.g. 5xx status codes).
  ///
  /// Uses [OutcomeClassifier.classifyResponse] to decide.
  final OutcomeClassifier? classifier;

  /// Optional side-effect callback fired just before [fallbackAction].
  ///
  /// Use for logging, metrics, or alerting.  Must not throw.
  final FallbackHttpCallback? onFallback;

  @override
  String toString() {
    final parts = <String>[];
    if (shouldHandle != null) parts.add('filtered');
    if (classifier != null) parts.add('classifier=${classifier.runtimeType}');
    return 'FallbackPolicy(${parts.isEmpty ? '' : parts.join(', ')})';
  }
}
