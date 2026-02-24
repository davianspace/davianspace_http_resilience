import '../core/http_context.dart';
import '../core/http_response.dart';

/// The fundamental unit of the HTTP middleware pipeline.
///
/// Every feature in the pipeline — resilience policies, logging, auth token
/// injection, caching — is implemented as an [HttpHandler].
///
/// Handlers form a **chain of responsibility**: each handler processes the
/// [HttpContext], optionally delegates to [`DelegatingHandler.innerHandler`], and
/// returns an [HttpResponse].
///
/// ### Implementing a custom handler
/// ```dart
/// final class MyLoggingHandler extends DelegatingHandler {
///   @override
///   Future<HttpResponse> send(HttpContext context) async {
///     print('→ ${context.request}');
///     final response = await super.send(context);
///     print('← $response');
///     return response;
///   }
/// }
/// ```
abstract class HttpHandler {
  /// Default constructor; `const`-eligible so that stateless handlers (e.g.
  /// [`NoOpPipeline`]) can be declared as compile-time constants.
  const HttpHandler();

  /// Processes the [context] and returns an [HttpResponse].
  ///
  /// Implementations should:
  /// * Call [`HttpContext.throwIfCancelled`] before long operations.
  /// * Propagate exceptions rather than swallowing them (unless a policy
  ///   explicitly handles them).
  /// * Never mutate [`context.request`] directly — use
  ///   [`HttpContext.updateRequest`] instead.
  Future<HttpResponse> send(HttpContext context);
}
