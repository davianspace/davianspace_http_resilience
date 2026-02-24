import '../core/cancellation_token.dart';
import '../core/http_context.dart';
import '../core/http_response.dart';
import '../exceptions/retry_exhausted_exception.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/retry_policy.dart';
import '../resilience/outcome_classification.dart';

/// A [DelegatingHandler] that retries transient failures according to a
/// [RetryPolicy].
///
/// [RetryHandler] wraps the inner handler and, on each failed attempt,
/// consults [RetryPolicy.shouldRetry] to decide whether to try again.
/// Between attempts it waits for the duration supplied by
/// [RetryPolicy.delayProvider] and increments [HttpContext.retryCount].
///
/// When all retries are exhausted a [RetryExhaustedException] is thrown.
///
/// ### Example
/// ```dart
/// final handler = RetryHandler(
///   RetryPolicy.exponential(maxRetries: 3, useJitter: true),
/// );
/// ```
final class RetryHandler extends DelegatingHandler {
  RetryHandler(this._policy);

  final RetryPolicy _policy;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    Object? lastException;
    HttpResponse? lastResponse;

    final totalAttempts = _policy.maxRetries + 1;

    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      context.retryCount = attempt;

      // Check policy-level cancellation token (independent of context token).
      if (_policy.cancellationToken?.isCancelled ?? false) {
        throw CancellationException(reason: _policy.cancellationToken?.reason);
      }

      try {
        final response = await innerHandler.send(context);

        if (!_policy.shouldRetry(response, null, context)) {
          return response;
        }

        lastResponse = response;
        lastException = null;
      } catch (e) {
        // Stash the exception so OutcomeClassifier.classify(context) can see it.
        context.setProperty(OutcomeClassifier.exceptionPropertyKey, e);
        if (!_policy.shouldRetry(null, e, context)) rethrow;
        lastException = e;
        lastResponse = null;
      }

      // Not the last attempt — back off before retry
      if (attempt < totalAttempts - 1) {
        context.throwIfCancelled();
        var delay = _policy.delayProvider(attempt + 1);

        // Honour server-requested Retry-After if the policy opts in.
        if (_policy.respectRetryAfterHeader && lastResponse != null) {
          final raDelay = _parseRetryAfter(
            lastResponse.headers['retry-after'] ??
                lastResponse.headers['Retry-After'],
          );
          if (raDelay != null) {
            final cap = _policy.maxRetryAfterDelay;
            delay = cap != null && raDelay > cap ? cap : raDelay;
          }
        }

        context.totalRetryDelay += delay;
        await Future.any<void>([
          Future<void>.delayed(delay),
          context.cancellationToken.onCancelled,
        ]);
        context.throwIfCancelled();
      }
    }

    throw RetryExhaustedException(
      attemptsMade: totalAttempts,
      cause: lastException,
    );
  }

  /// Parses a `Retry-After` header value into a [Duration].
  ///
  /// Handles numeric seconds only (e.g. `"120"` → `Duration(seconds: 120)`).
  /// Returns `null` for absent or non-numeric values (HTTP-date format is not
  /// parsed to avoid a `dart:io` dependency).
  static Duration? _parseRetryAfter(String? headerValue) {
    if (headerValue == null) return null;
    final seconds = int.tryParse(headerValue.trim());
    if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    return null;
  }
}
