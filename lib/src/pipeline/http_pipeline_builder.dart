import '../core/http_context.dart';
import '../core/http_response.dart';
import 'delegating_handler.dart';
import 'http_handler.dart';
import 'terminal_handler.dart';

/// Builds an ordered [HttpHandler] chain from a list of middleware components.
///
/// Handlers are executed in the order they are added. The first handler added
/// is the outermost (first to execute, last to return); the [TerminalHandler]
/// is always appended as the innermost handler.
///
/// > **Internal implementation detail.** Use `HttpClientFactory` to build
/// > pipelines. Call `.addHandler()` on the builder for custom middleware.
final class HttpPipelineBuilder {
  final List<DelegatingHandler> _handlers = [];
  TerminalHandler? _terminalHandler;

  /// Appends [handler] to the current middleware chain.
  ///
  /// Returns `this` for fluent chaining.
  HttpPipelineBuilder addHandler(DelegatingHandler handler) {
    _handlers.add(handler);
    return this;
  }

  /// Overrides the default [TerminalHandler].
  ///
  /// Useful for injecting a mock HTTP client in tests.
  HttpPipelineBuilder withTerminalHandler(TerminalHandler handler) {
    _terminalHandler = handler;
    return this;
  }

  /// Assembles and returns the root [HttpHandler].
  ///
  /// The handlers are linked in reverse order so that the first added handler
  /// is the outermost (called first). The [TerminalHandler] is wired as the
  /// inner handler of the deepest [DelegatingHandler].
  ///
  /// Throws [StateError] if the builder has no handlers and no terminal
  /// handler — at minimum one must be present.
  HttpHandler build() {
    final terminal = _terminalHandler ?? TerminalHandler();

    if (_handlers.isEmpty) return terminal;

    // Wire up chain from innermost to outermost.
    HttpHandler inner = terminal;
    for (final handler in _handlers.reversed) {
      handler.innerHandler = inner;
      inner = handler;
    }

    return inner;
  }
}

// ---------------------------------------------------------------------------
// Null-Object / pass-through pipeline (useful for testing)
// ---------------------------------------------------------------------------

/// A no-op pipeline that always returns [HttpResponse.ok].
///
/// Useful as a stand-in in widget tests or unit tests that don't exercise
/// the network layer.
final class NoOpPipeline extends HttpHandler {
  const NoOpPipeline();

  @override
  Future<HttpResponse> send(HttpContext context) async => HttpResponse.ok();
}
