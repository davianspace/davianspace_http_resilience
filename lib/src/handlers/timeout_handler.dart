import 'dart:async' show TimeoutException;

import '../core/http_context.dart';
import '../core/http_response.dart';
import '../exceptions/http_timeout_exception.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/timeout_policy.dart';

/// A [DelegatingHandler] that enforces per-attempt or total operation timeouts.
///
/// When the deadline is exceeded the inner handler's future is abandoned and
/// an [HttpTimeoutException] is thrown.
///
/// ## Important: abandoned in-flight requests
///
/// When a timeout fires, [TimeoutHandler] stops waiting for the response
/// but **does NOT cancel** the underlying HTTP request. The in-flight
/// call continues to completion in the background (consuming network
/// resources and server capacity). This is a Dart platform limitation:
/// `Future.timeout()` cannot cancel the underlying I/O.
///
/// If you need true request cancellation, consider:
/// 1. Using `CancellationToken` in combination with a cancellation-aware
///    HTTP client adapter.
/// 2. Setting socket-level timeouts on the underlying `http.Client`.
///
/// ### Example
/// ```dart
/// final handler = TimeoutHandler(
///   TimeoutPolicy(timeout: Duration(seconds: 10)),
/// );
/// ```
final class TimeoutHandler extends DelegatingHandler {
  TimeoutHandler(this._policy);

  final TimeoutPolicy _policy;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    try {
      return await innerHandler.send(context).timeout(_policy.timeout);
    } on TimeoutException {
      // Note: the inner handler's future is abandoned but NOT cancelled.
      // Dart's Future.timeout() stops waiting but cannot cancel the
      // underlying I/O — this is a platform limitation.
      //
      // We intentionally do NOT cancel context.cancellationToken here because
      // the context token spans the entire multi-attempt operation (including
      // retries). Cancelling it would prevent retry handlers from making
      // further attempts. The abandoned future will eventually complete
      // and be garbage collected.
      throw HttpTimeoutException(timeout: _policy.timeout);
    }
  }
}
