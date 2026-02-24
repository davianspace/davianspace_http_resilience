import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../core/http_context.dart';
import '../core/http_request.dart';
import '../core/http_response.dart';
import 'http_handler.dart';

/// The innermost [HttpHandler] in every pipeline.
///
/// [TerminalHandler] performs the actual HTTP I/O using Dart's `http` package.
/// It converts the pipeline's [HttpRequest] into a `package:http` [http.Request],
/// executes it, and converts the raw [http.StreamedResponse] back into an
/// [HttpResponse].
///
/// You should never place another handler after [TerminalHandler] in the chain.
///
/// ### Streaming mode
///
/// By default the response body is eagerly buffered so that the body bytes are
/// available as `List<int>` when [send] returns.
///
/// Set `streamingMode: true` to skip buffering.  The returned [HttpResponse]
/// will have `isStreaming == true` and the bytes can be read via
/// [HttpResponse.bodyStream].  The `duration` field reflects the
/// time-to-first-byte (TTFB) rather than the full content-transfer time.
///
/// **Important:** streaming responses are incompatible with `RetryHandler` and
/// `CircuitBreakerHandler` when those handlers need to inspect the body bytes.
/// Use `response.toBuffered()` inside a custom handler when this matters.
///
/// > **Internal implementation detail.** Use `HttpClientFactory` /
/// > `HttpClientBuilder` to build pipelines rather than creating
/// > `TerminalHandler` instances directly.
@internal
final class TerminalHandler extends HttpHandler {
  /// Creates a [TerminalHandler] backed by [client].
  ///
  /// [client]        — an optional [http.Client]; a new [http.Client] is
  ///                   created if none is provided. Inject a mock client in
  ///                   tests.
  /// [streamingMode] — when `true`, the response body is returned as a
  ///                   `Stream<List<int>>` without buffering.  Default: `false`.
  TerminalHandler({http.Client? client, this.streamingMode = false})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;

  /// `true` when [TerminalHandler] created the [http.Client] internally.
  ///
  /// Only internally-owned clients are closed in [dispose]; injected clients
  /// remain the caller's responsibility.
  final bool _ownsClient;

  /// When `true`, the response body is not buffered — it is exposed as a
  /// `Stream<List<int>>` via [HttpResponse.bodyStream].
  final bool streamingMode;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    final req = _buildHttpRequest(context.request);
    final stopwatch = Stopwatch()..start();

    try {
      final streamed = await _client.send(req);

      if (streamingMode) {
        // Return immediately after receiving headers / first byte.
        stopwatch.stop();
        return HttpResponse.streaming(
          statusCode: streamed.statusCode,
          headers: Map<String, String>.from(streamed.headers),
          bodyStream: streamed.stream,
          duration: stopwatch.elapsed,
        );
      }

      final bodyBytes = await streamed.stream.toBytes();
      stopwatch.stop();

      return HttpResponse(
        statusCode: streamed.statusCode,
        headers: Map<String, String>.from(streamed.headers),
        body: bodyBytes,
        duration: stopwatch.elapsed,
      );
    } on Exception {
      stopwatch.stop();
      rethrow;
    }
  }

  /// Closes the underlying [http.Client] when it was created internally.
  ///
  /// Only closes the client when [TerminalHandler] created it (i.e. no
  /// external [http.Client] was injected via the constructor).  Injected
  /// clients are not closed because the caller retains ownership.
  void dispose() {
    if (_ownsClient) _client.close();
  }

  http.Request _buildHttpRequest(HttpRequest request) {
    final httpReq = http.Request(
      request.method.value,
      request.uri,
    );

    httpReq.headers.addAll(request.headers);

    final body = request.body;
    if (body != null) {
      httpReq.bodyBytes = body;
    }

    return httpReq;
  }
}
