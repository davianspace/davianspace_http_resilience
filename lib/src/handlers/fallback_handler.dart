import '../core/http_context.dart';
import '../core/http_response.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/fallback_policy.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  FallbackHandler
// ═══════════════════════════════════════════════════════════════════════════

/// A [`DelegatingHandler`] that executes the inner pipeline and, on failure,
/// delegates to the [`FallbackPolicy.fallbackAction`] configured in [`policy].
///
/// ## Failure conditions
///
/// The fallback fires when:
/// 1. The inner pipeline throws an exception *and*
///    [`FallbackPolicy.shouldHandle`] is `null` or returns `true` for it.
/// 2. The inner pipeline returns an [`HttpResponse`] *and* either:
///    - [`FallbackPolicy.shouldHandle`] returns `true` for the response, or
///    - [`FallbackPolicy.classifier`] classifies the response as a failure.
///
/// In all other cases the original response or exception is forwarded
/// unchanged.
///
/// ## Insertion order
///
/// Add [`FallbackHandler`] **before** retry / circuit-breaker handlers so it
/// wraps them and catches their final exceptions:
///
/// ```dart
/// HttpClientFactory.createBuilder()
///     .withFallback(policy)      // outermost — catches everything inside
///     .withRetry(retryPolicy)
///     .withTimeout(timeout)
///     .build();
/// ```
/// Internally [`FallbackHandler`] is created by [`HttpClientBuilder.withFallback`].
final class FallbackHandler extends DelegatingHandler {
  /// Creates a [`FallbackHandler`] from the provided [`policy`].
  FallbackHandler(this._policy);

  final FallbackPolicy _policy;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    HttpResponse? response;

    try {
      response = await innerHandler.send(context);

      // ── Response-based fallback ─────────────────────────────────────────

      final predicate = _policy.shouldHandle;

      // 1. shouldHandle predicate (highest priority for response checks).
      if (predicate != null) {
        if (predicate(response, null, context)) {
          _notifyOnFallback(context, null, null);
          return await _policy.fallbackAction(context, null, null);
        }
        // Predicate present but returned false — do NOT also run classifier.
        return response;
      }

      // 2. OutcomeClassifier fallback (only when shouldHandle is absent).
      final cl = _policy.classifier;
      if (cl != null && cl.classifyResponse(response).isFailure) {
        _notifyOnFallback(context, null, null);
        return await _policy.fallbackAction(context, null, null);
      }

      return response;
    } catch (e, st) {
      // ── Exception-based fallback ────────────────────────────────────────

      final predicate = _policy.shouldHandle;

      if (predicate != null && !predicate(null, e, context)) {
        // Non-matching exception — propagate unchanged.
        Error.throwWithStackTrace(e, st);
      }

      _notifyOnFallback(context, e, st);
      return _policy.fallbackAction(context, e, st);
    }
  }

  /// Safely invokes [FallbackPolicy.onFallback], swallowing errors so that a
  /// misbehaving callback cannot prevent the fallback action from executing.
  void _notifyOnFallback(
    HttpContext context,
    Object? error,
    StackTrace? stackTrace,
  ) {
    try {
      _policy.onFallback?.call(context, error, stackTrace);
    } on Object catch (_) {
      // Intentionally swallowed — onFallback is observational and must not
      // prevent the fallback action from executing.
    }
  }

  @override
  String toString() => 'FallbackHandler($_policy)';
}
