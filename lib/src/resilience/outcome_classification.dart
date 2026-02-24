import '../core/http_context.dart';
import '../core/http_response.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  OutcomeClassification enum
// ═══════════════════════════════════════════════════════════════════════════

/// The outcome category assigned to a completed HTTP operation.
///
/// Classification drives retry and resilience decisions: only
/// [transientFailure] outcomes are considered worth retrying.
///
/// ```dart
/// final classification = const HttpOutcomeClassifier()
///     .classifyResponse(HttpResponse(statusCode: 503));
///
/// if (classification.isRetryable) {
///   // schedule retry
/// }
/// ```
enum OutcomeClassification {
  /// The operation completed successfully (e.g., 2xx status code).
  success,

  /// A transient failure occurred — the operation *may* succeed on retry.
  ///
  /// Typical causes: 5xx server errors, network timeouts, connection refused.
  transientFailure,

  /// A permanent failure occurred — retrying will **not** help.
  ///
  /// Typical causes: 4xx client errors (bad request, unauthorised, not found).
  permanentFailure;

  /// `true` when this classification indicates a successful outcome.
  bool get isSuccess => this == success;

  /// `true` when this outcome is considered safe to retry.
  ///
  /// Only [transientFailure] returns `true`; [success] and [permanentFailure]
  /// both return `false`.
  bool get isRetryable => this == transientFailure;

  /// `true` when the operation did *not* succeed (either transient or
  /// permanent failure).
  bool get isFailure => this != success;
}

// ═══════════════════════════════════════════════════════════════════════════
//  OutcomeClassifier base class
// ═══════════════════════════════════════════════════════════════════════════

/// Determines how an HTTP operation outcome should be classified.
///
/// Implement [classifyResponse] and [classifyException] to inject custom
/// classification logic into any policy that accepts an [OutcomeClassifier].
/// The provided [classify] method works without overriding: it reads the
/// current [response][HttpContext.response] or the stashed exception from the
/// context property bag and delegates to the two abstract helpers.
///
/// ## Default implementation
///
/// [HttpOutcomeClassifier] provides HTTP-idiomatic defaults:
///
/// | Situation        | Classification             |
/// |------------------|----------------------------|
/// | 2xx response     | [OutcomeClassification.success]            |
/// | 5xx response     | [OutcomeClassification.transientFailure]   |
/// | 4xx response     | [OutcomeClassification.permanentFailure]   |
/// | Any exception    | [OutcomeClassification.transientFailure]   |
///
/// ## Custom classifier — example
///
/// ```dart
/// /// Treats 429 Too Many Requests as transient (retry with back-off) and
/// /// delegates everything else to the default HTTP rules.
/// final class ThrottleAwareClassifier extends OutcomeClassifier {
///   const ThrottleAwareClassifier();
///
///   @override
///   OutcomeClassification classifyResponse(HttpResponse response) {
///     if (response.statusCode == 429) return OutcomeClassification.transientFailure;
///     return const HttpOutcomeClassifier().classifyResponse(response);
///   }
///
///   @override
///   OutcomeClassification classifyException(Object exception) =>
///       OutcomeClassification.transientFailure;
/// }
/// ```
///
/// ## Usage with policies
///
/// ```dart
/// final policy = RetryResiliencePolicy.withClassifier(
///   maxRetries: 3,
///   backoff: ExponentialBackoff(Duration(milliseconds: 200)),
///   classifier: ThrottleAwareClassifier(),
/// );
///
/// // Or via the pipeline builder:
/// final pipeline = ResiliencePipelineBuilder()
///     .addClassifiedRetry(
///         maxRetries: 3,
///         classifier: ThrottleAwareClassifier(),
///       )
///     .build();
/// ```
abstract class OutcomeClassifier {
  const OutcomeClassifier();

  // -------------------------------------------------------------------------
  // Well-known property key
  // -------------------------------------------------------------------------

  /// Property-bag key used to stash the current exception in [HttpContext].
  ///
  /// [`RetryHandler`] writes the caught exception under this key before calling
  /// [classify] so that classifier implementations can inspect both the
  /// [HttpContext.response] **and** the thrown error through the same
  /// [classify] call.
  ///
  /// Custom classifiers that need the raw exception within [classify] should
  /// read it from [HttpContext.getProperty]:
  ///
  /// ```dart
  /// @override
  /// OutcomeClassification classify(HttpContext context) {
  ///   final ex = context.getProperty<Object>(OutcomeClassifier.exceptionPropertyKey);
  ///   if (ex is MyDomainException) return OutcomeClassification.permanentFailure;
  ///   return super.classify(context);
  /// }
  /// ```
  static const String exceptionPropertyKey = 'outcome.classifier.exception';

  // -------------------------------------------------------------------------
  // Primary context-aware entry point
  // -------------------------------------------------------------------------

  /// Classifies the current state of [context].
  ///
  /// The default implementation:
  /// 1. Returns [classifyResponse] if [HttpContext.response] is set.
  /// 2. Falls back to [classifyException] when an exception has been stashed
  ///    at [exceptionPropertyKey] in the context property bag.
  /// 3. Returns [OutcomeClassification.success] when neither is present.
  ///
  /// Override this method when you need direct access to the full [HttpContext]
  /// (e.g., to inspect [HttpContext.retryCount] or custom properties).
  OutcomeClassification classify(HttpContext context) {
    final response = context.response;
    if (response != null) return classifyResponse(response);

    final exception = context.getProperty<Object>(exceptionPropertyKey);
    if (exception != null) return classifyException(exception);

    return OutcomeClassification.success;
  }

  // -------------------------------------------------------------------------
  // Focused helpers — implement these in subclasses
  // -------------------------------------------------------------------------

  /// Classifies a raw [HttpResponse] without an [HttpContext].
  ///
  /// Used by free-standing policies (`RetryResiliencePolicy`) that operate on
  /// responses directly rather than through the handler pipeline.
  OutcomeClassification classifyResponse(HttpResponse response);

  /// Classifies an [exception] that prevented a response from being received.
  ///
  /// Used when no response is available — network failures, timeouts, etc.
  OutcomeClassification classifyException(Object exception);
}

// ═══════════════════════════════════════════════════════════════════════════
//  HttpOutcomeClassifier — default implementation
// ═══════════════════════════════════════════════════════════════════════════

/// The default HTTP outcome classifier.
///
/// Applies standard HTTP semantics:
///
/// | Status range | Classification             |
/// |--------------|----------------------------|
/// | 2xx          | [OutcomeClassification.success]            |
/// | 5xx          | [OutcomeClassification.transientFailure]   |
/// | 4xx          | [OutcomeClassification.permanentFailure]   |
/// | 3xx / other  | [OutcomeClassification.permanentFailure]   |
/// | Exception    | [OutcomeClassification.transientFailure]   |
///
/// [HttpOutcomeClassifier] is **stateless** and `const`-constructible; a
/// single instance can be safely shared across the entire application:
///
/// ```dart
/// static const classifier = HttpOutcomeClassifier();
/// ```
final class HttpOutcomeClassifier extends OutcomeClassifier {
  /// Creates a const-constructible [HttpOutcomeClassifier].
  const HttpOutcomeClassifier();

  @override
  OutcomeClassification classifyResponse(HttpResponse response) {
    // 2xx — success
    if (response.isSuccess) return OutcomeClassification.success;
    // 5xx — transient (server-side; worth retrying)
    if (response.isServerError) return OutcomeClassification.transientFailure;
    // Everything else (4xx, 3xx, 1xx) — permanent (client-side; retry won't help)
    return OutcomeClassification.permanentFailure;
  }

  @override
  OutcomeClassification classifyException(Object exception) =>
      // All exceptions are treated as transient: network errors, DNS failures,
      // connection timeouts, etc. can all be resolved by retrying.
      OutcomeClassification.transientFailure;

  @override
  String toString() => 'HttpOutcomeClassifier';
}

// ═══════════════════════════════════════════════════════════════════════════
//  CompositeOutcomeClassifier — classifier composition
// ═══════════════════════════════════════════════════════════════════════════

/// Chains multiple [OutcomeClassifier] instances: the first classifier that
/// returns a **non-success** result wins.
///
/// This lets you layer specialised classifiers on top of the HTTP default
/// without losing its general-purpose rules:
///
/// ```dart
/// final classifier = CompositeOutcomeClassifier([
///   BusinessErrorClassifier(),  // checked first
///   HttpOutcomeClassifier(),    // fallback for HTTP rules
/// ]);
/// ```
///
/// [classifyException] uses the same first-fail strategy; when all inner
/// classifiers return [OutcomeClassification.success] (which should never
/// happen for an exception pathway) it falls back to [OutcomeClassification.transientFailure].
final class CompositeOutcomeClassifier extends OutcomeClassifier {
  /// Creates a [CompositeOutcomeClassifier] from [classifiers].
  ///
  /// [classifiers] must not be empty.
  const CompositeOutcomeClassifier(this.classifiers);

  /// The ordered list of inner classifiers.
  final List<OutcomeClassifier> classifiers;

  @override
  OutcomeClassification classifyResponse(HttpResponse response) {
    for (final c in classifiers) {
      final result = c.classifyResponse(response);
      if (result != OutcomeClassification.success) return result;
    }
    return OutcomeClassification.success;
  }

  @override
  OutcomeClassification classifyException(Object exception) {
    for (final c in classifiers) {
      final result = c.classifyException(exception);
      if (result != OutcomeClassification.success) return result;
    }
    // Safety net: an uncaught exception is always at least transient.
    return OutcomeClassification.transientFailure;
  }

  @override
  String toString() => 'CompositeOutcomeClassifier(${classifiers.length})';
}

// ═══════════════════════════════════════════════════════════════════════════
//  PredicateOutcomeClassifier — adapts existing Dart predicates
// ═══════════════════════════════════════════════════════════════════════════

/// A typedef for a response-level classification predicate.
typedef ResponseClassificationPredicate = OutcomeClassification Function(
  HttpResponse response,
);

/// A typedef for an exception-level classification predicate.
typedef ExceptionClassificationPredicate = OutcomeClassification Function(
  Object exception,
);

/// Adapts plain Dart functions into an [OutcomeClassifier].
///
/// Useful when you want to define classification logic inline without
/// creating a full subclass:
///
/// ```dart
/// final classifier = PredicateOutcomeClassifier(
///   responseClassifier: (r) => r.statusCode == 429
///       ? OutcomeClassification.transientFailure
///       : const HttpOutcomeClassifier().classifyResponse(r),
///   exceptionClassifier: (_) => OutcomeClassification.transientFailure,
/// );
/// ```
final class PredicateOutcomeClassifier extends OutcomeClassifier {
  /// Creates a [PredicateOutcomeClassifier].
  ///
  /// [responseClassifier]  — called for every HTTP response.
  /// [exceptionClassifier] — called when an exception is available; defaults
  ///                         to treating all exceptions as transient.
  const PredicateOutcomeClassifier({
    required ResponseClassificationPredicate responseClassifier,
    ExceptionClassificationPredicate? exceptionClassifier,
  })  : _responseClassifier = responseClassifier,
        _exceptionClassifier = exceptionClassifier;

  final ResponseClassificationPredicate _responseClassifier;
  final ExceptionClassificationPredicate? _exceptionClassifier;

  @override
  OutcomeClassification classifyResponse(HttpResponse response) =>
      _responseClassifier(response);

  @override
  OutcomeClassification classifyException(Object exception) =>
      _exceptionClassifier?.call(exception) ??
      OutcomeClassification.transientFailure;

  @override
  String toString() => 'PredicateOutcomeClassifier';
}
