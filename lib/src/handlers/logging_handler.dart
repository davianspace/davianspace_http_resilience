import 'dart:convert';

import 'package:logging/logging.dart';

import '../core/http_context.dart';
import '../core/http_response.dart';
import '../pipeline/delegating_handler.dart';

/// A [DelegatingHandler] that emits structured log entries via the `logging`
/// package for every request/response pair passing through the pipeline.
///
/// Log messages are emitted on the [Logger] provided at construction time,
/// defaulting to a logger named `davianspace.http`.
///
/// | Condition                   | Level   |
/// |-----------------------------|---------|
/// | Request sent                | [Level.INFO]  |
/// | Successful response (2xx)   | [Level.INFO]  |
/// | Redirect (3xx)              | [Level.INFO]  |
/// | Client error (4xx)          | [Level.WARNING] |
/// | Server error (5xx)          | [Level.SEVERE] |
/// | Unhandled exception         | [Level.SEVERE] |
///
/// ### URI sanitization
///
/// By default, query parameters are stripped from logged URIs to prevent
/// leaking API keys or tokens that are passed as query strings:
///
/// ```
/// GET /search  (query params stripped)
/// ```
///
/// To log the full URI, pass the identity sanitizer:
///
/// ```dart
/// LoggingHandler(uriSanitizer: (u) => u.toString());
/// ```
///
/// ### Example
/// ```dart
/// // Configure the logging package once at app startup
/// Logger.root.level = Level.ALL;
/// Logger.root.onRecord.listen((r) => print('[${r.level}] ${r.message}'));
///
/// final handler = LoggingHandler();
/// ```
final class LoggingHandler extends DelegatingHandler {
  /// Creates a [LoggingHandler].
  ///
  /// [logger]       — custom [Logger] instance; defaults to one named
  ///                  `davianspace.http`.
  /// [uriSanitizer] — transforms a request [Uri] into the string that will
  ///                  appear in log messages. Defaults to stripping query
  ///                  parameters so secrets in query strings are not logged.
  /// Creates a [LoggingHandler].
  ///
  /// [logger]       — custom [Logger] instance; defaults to one named
  ///                  `davianspace.http`.
  /// [uriSanitizer] — transforms a request [Uri] into the string that will
  ///                  appear in log messages. Defaults to stripping query
  ///                  parameters so secrets in query strings are not logged.
  /// [structured]   — when `true`, log messages are emitted as JSON objects
  ///                  instead of human-readable text (default `false`).
  LoggingHandler({
    Logger? logger,
    String Function(Uri)? uriSanitizer,
    bool structured = false,
  })  : _logger = logger ?? Logger('davianspace.http'),
        _uriSanitizer = uriSanitizer ?? _defaultSanitizer,
        _structured = structured;

  final Logger _logger;
  final String Function(Uri) _uriSanitizer;
  final bool _structured;

  static String _defaultSanitizer(Uri uri) =>
      uri.replace(queryParameters: const {}).toString();

  @override
  Future<HttpResponse> send(HttpContext context) async {
    final req = context.request;
    final uriLabel = _uriSanitizer(req.uri);

    if (_structured) {
      _logger.info(
        jsonEncode({
          'event': 'request',
          'method': req.method.value,
          'uri': uriLabel,
        }),
      );
    } else {
      _logger.info('→ ${req.method.value} $uriLabel');
    }

    final stopwatch = Stopwatch()..start();

    try {
      final response = await innerHandler.send(context);
      stopwatch.stop();

      final level = _levelFor(response.statusCode);
      if (_structured) {
        _logger.log(
          level,
          jsonEncode({
            'event': 'response',
            'method': req.method.value,
            'uri': uriLabel,
            'status': response.statusCode,
            'durationMs': stopwatch.elapsedMilliseconds,
            'retryCount': context.retryCount,
          }),
        );
      } else {
        _logger.log(
          level,
          '← ${response.statusCode} $uriLabel '
          '[${stopwatch.elapsedMilliseconds}ms] retry=${context.retryCount}',
        );
      }

      return response;
    } catch (e, st) {
      stopwatch.stop();
      if (_structured) {
        _logger.severe(
          jsonEncode({
            'event': 'error',
            'method': req.method.value,
            'uri': uriLabel,
            'durationMs': stopwatch.elapsedMilliseconds,
            'error': e.toString(),
          }),
          e,
          st,
        );
      } else {
        _logger.severe(
          '✗ ${req.method.value} $uriLabel threw after '
          '${stopwatch.elapsedMilliseconds}ms: $e',
          e,
          st,
        );
      }
      rethrow;
    }
  }

  Level _levelFor(int statusCode) {
    if (statusCode >= 500) return Level.SEVERE;
    if (statusCode >= 400) return Level.WARNING;
    return Level.INFO;
  }
}
