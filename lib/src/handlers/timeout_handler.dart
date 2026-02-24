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
      // Note: we do NOT cancel context.cancellationToken here — the context
      // token spans the entire multi-attempt operation (including retries), so
      // cancelling it here would prevent retry handlers from making further
      // attempts.  Timeout enforcement is handled purely by the abandoned future.
      throw HttpTimeoutException(timeout: _policy.timeout);
    }
  }
}
