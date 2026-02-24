import 'package:http/http.dart' as http;

import '../core/http_context.dart';
import '../core/http_response.dart';
import 'delegating_handler.dart';
import 'http_handler.dart';
import 'terminal_handler.dart';

/// A directly-instantiable HTTP middleware pipeline that wires a list of
/// handlers in a single constructor call.
///
/// [HttpPipeline] is the list-style counterpart to [`HttpPipelineBuilder`].
/// It is ideal when the full set of handlers is known at construction time
/// and a fluent builder interface is not required.
///
/// ### Usage
/// ```dart
/// final pipeline = HttpPipeline([
///   LoggingHandler(),
///   RetryHandler(RetryPolicy.exponential(maxRetries: 3)),
///   CircuitBreakerHandler(CircuitBreakerPolicy(circuitName: 'svc')),
///   TimeoutHandler(TimeoutPolicy(timeout: Duration(seconds: 10))),
///   // TerminalHandler is auto-appended when the last item is a
///   // [`DelegatingHandler`] — or you can supply your own:
///   TerminalHandler(),
/// ]);
///
/// final context = HttpContext(
///   request: HttpRequest(method: HttpMethod.get, uri: Uri.parse('...')),
/// );
/// final response = await pipeline.send(context);
/// ```
///
/// ### Handler ordering
/// Handlers are listed **outermost → innermost**.  The first handler in the
/// list executes first; the last (or the auto-appended [TerminalHandler])
/// performs the actual network call.
///
/// ### Thread safety
/// [HttpPipeline] is immutable after construction.  The wired handler chain
/// is built once and the same chain is shared across all concurrent `send()`
/// calls.  Each individual `send()` runs within its own [HttpContext] so
/// there is no shared mutable state between concurrent requests.
///
/// ### Auto-terminal
/// If the last handler provided is a [DelegatingHandler], an un-configured
/// [TerminalHandler] is automatically appended.  Supply an explicit
/// [TerminalHandler] (or override via [`httpClient`]) to control the underlying
/// [http.Client] instance.
final class HttpPipeline extends HttpHandler {
  /// Constructs a pipeline from [handlers], wiring them in order.
  ///
  /// [handlers]   — ordered list, outermost first.  All items except the last
  ///               **must** be [DelegatingHandler] instances.  The last item
  ///               may be any [HttpHandler]; if it is a [DelegatingHandler],
  ///               a [TerminalHandler] is appended automatically.
  ///
  /// [httpClient] — optional [http.Client] used **only** when a
  ///               [TerminalHandler] is auto-appended (ignored when the caller
  ///               supplies an explicit terminal handler).
  ///
  /// Throws [ArgumentError] if a non-terminal, non-[DelegatingHandler] is
  /// found at any position other than the last.
  HttpPipeline(
    List<HttpHandler> handlers, {
    http.Client? httpClient,
  }) : _root = _wire(List<HttpHandler>.unmodifiable(handlers), httpClient);

  final HttpHandler _root;

  /// The outermost handler — the entry-point of the chain.
  HttpHandler get root => _root;

  /// Total number of handlers in the pipeline, including the terminal.
  ///
  /// Useful for diagnostic tooling.
  int get length => _countHandlers(_root);

  @override
  Future<HttpResponse> send(HttpContext context) => _root.send(context);

  /// Releases resources held by handlers in the pipeline.
  ///
  /// Walks the handler chain and disposes any [TerminalHandler] found,
  /// closing internally-owned [http.Client] instances.
  void dispose() {
    var current = _root as HttpHandler?;
    while (current != null) {
      if (current is TerminalHandler) {
        current.dispose();
        break;
      }
      if (current is DelegatingHandler && current.hasInnerHandler) {
        current = current.innerHandler;
      } else {
        break;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Internal wiring
  // ---------------------------------------------------------------------------

  /// Wires the handler list and returns the outermost handler.
  static HttpHandler _wire(
    List<HttpHandler> handlers,
    http.Client? httpClient,
  ) {
    if (handlers.isEmpty) {
      return TerminalHandler(client: httpClient);
    }

    // Determine whether to auto-append a TerminalHandler.
    final bool autoTerminal = handlers.last is DelegatingHandler;

    // The innermost (terminal) handler.
    final HttpHandler terminal =
        autoTerminal ? TerminalHandler(client: httpClient) : handlers.last;

    // Number of DelegatingHandler items to link (all except the last when
    // the last is a non-DelegatingHandler).
    final int limit = autoTerminal ? handlers.length : handlers.length - 1;

    // Validate that all non-terminal positions hold DelegatingHandler instances.
    for (var i = 0; i < limit; i++) {
      final h = handlers[i];
      if (h is! DelegatingHandler) {
        throw ArgumentError(
          'handlers[$i] is a ${h.runtimeType}, which is not a '
              'DelegatingHandler. Only the last handler in the list may be a '
              'plain HttpHandler (acting as the terminal). All other entries '
              'must extend DelegatingHandler.',
          'handlers',
        );
      }
    }

    // Link from innermost outward.
    HttpHandler inner = terminal;
    for (var i = limit - 1; i >= 0; i--) {
      final delegating = handlers[i] as DelegatingHandler;
      delegating.innerHandler = inner;
      inner = delegating;
    }

    return inner;
  }

  int _countHandlers(HttpHandler h) {
    var count = 1;
    var current = h;
    while (current is DelegatingHandler && current.hasInnerHandler) {
      current = current.innerHandler;
      count++;
    }
    return count;
  }

  @override
  String toString() => 'HttpPipeline(length=$length)';
}
