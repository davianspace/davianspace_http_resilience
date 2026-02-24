import '../core/http_context.dart';
import '../core/http_response.dart';
import 'http_handler.dart';

/// An [HttpHandler] that holds a reference to the next handler in the chain.
///
/// Middleware authors should extend [DelegatingHandler] rather than
/// [HttpHandler] directly whenever they need access to an inner handler.
///
/// The [innerHandler] **must** be set before [send] is called. The pipeline
/// builder (see [`HttpPipelineBuilder`]) wires up the chain automatically.
///
/// ### Implementing a custom handler
/// ```dart
/// final class MyHandler extends DelegatingHandler {
///   @override
///   Future<HttpResponse> send(HttpContext context) async {
///     final response = await innerHandler.send(context);
///     return response;
///   }
/// }
/// ```
abstract class DelegatingHandler extends HttpHandler {
  /// Creates a [DelegatingHandler].
  ///
  /// Subclasses invoke this implicitly or via `super()`.
  DelegatingHandler();

  HttpHandler? _innerHandler;

  /// The next handler in the chain.
  ///
  /// Throws [StateError] if accessed before assignment.
  HttpHandler get innerHandler {
    if (_innerHandler == null) {
      throw StateError(
        '$runtimeType.innerHandler is null. '
        'Ensure the pipeline was built via HttpPipelineBuilder.build().',
      );
    }
    return _innerHandler!;
  }

  /// Sets the next handler in the chain.
  ///
  /// Should only be set once during pipeline construction. Reassigning
  /// after the pipeline is built may cause unexpected behavior.
  set innerHandler(HttpHandler handler) => _innerHandler = handler;

  /// Returns `true` when an inner handler has been assigned.
  bool get hasInnerHandler => _innerHandler != null;

  /// Delegates the [context] to [innerHandler].
  @override
  Future<HttpResponse> send(HttpContext context) => innerHandler.send(context);
}
