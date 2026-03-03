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

        // Drain any previous streaming response before discarding it (FIX-03).
        _drainIfStreaming(lastResponse);
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

    // Drain the final response before throwing (FIX-03).
    _drainIfStreaming(lastResponse);

    throw RetryExhaustedException(
      attemptsMade: totalAttempts,
      cause: lastException,
    );
  }

  /// Drains the body stream of a streaming response to free the TCP connection
  /// (FIX-03).
  static void _drainIfStreaming(HttpResponse? response) {
    if (response != null && response.isStreaming) {
      response.bodyStream.drain<void>().catchError((_) {});
    }
  }

  /// Parses a `Retry-After` header value into a [Duration].
  ///
  /// Handles both numeric seconds (e.g. `"120"`) and RFC 9110 §10.2.3
  /// IMF-fixdate HTTP-date format (e.g. `"Wed, 21 Oct 2025 07:28:00 GMT"`).
  /// Returns `null` for absent or unparseable values.
  static Duration? _parseRetryAfter(String? headerValue) {
    if (headerValue == null) return null;
    final trimmed = headerValue.trim();

    // 1. Try numeric seconds (most common).
    final seconds = int.tryParse(trimmed);
    if (seconds != null && seconds > 0) return Duration(seconds: seconds);

    // 2. Try HTTP-date format (RFC 9110 §10.2.3).
    final date = _tryParseHttpDate(trimmed);
    if (date != null) {
      final delta = date.difference(DateTime.now().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    }

    return null;
  }

  /// Parses an IMF-fixdate string (e.g. `"Sun, 06 Nov 1994 08:49:37 GMT"`).
  /// Returns `null` if parsing fails.
  static DateTime? _tryParseHttpDate(String value) {
    try {
      const months = {
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4,
        'May': 5, 'Jun': 6, 'Jul': 7, 'Aug': 8,
        'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      final parts = value.split(' ');
      if (parts.length != 6 || parts[5] != 'GMT') return null;
      final day = int.parse(parts[1]);
      final month = months[parts[2]];
      if (month == null) return null;
      final year = int.parse(parts[3]);
      final timeParts = parts[4].split(':');
      if (timeParts.length != 3) return null;
      return DateTime.utc(
        year,
        month,
        day,
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } on Object catch (_) {
      return null;
    }
  }
}
