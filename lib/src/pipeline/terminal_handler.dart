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
/// > **Internal implementation detail.** Use `HttpClientFactory` /
/// > `HttpClientBuilder` to build pipelines rather than creating
/// > `TerminalHandler` instances directly.
@internal
final class TerminalHandler extends HttpHandler {
  /// Creates a [TerminalHandler] backed by [client].
  ///
  /// [client] — an optional [http.Client]; a new [http.Client] is created if
  /// none is provided. Inject a mock client in tests.
  TerminalHandler({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;

  /// `true` when [TerminalHandler] created the [http.Client] internally.
  ///
  /// Only internally-owned clients are closed in [dispose]; injected clients
  /// remain the caller's responsibility.
  final bool _ownsClient;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    final req = _buildHttpRequest(context.request);
    final stopwatch = Stopwatch()..start();

    try {
      final streamed = await _client.send(req);
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
