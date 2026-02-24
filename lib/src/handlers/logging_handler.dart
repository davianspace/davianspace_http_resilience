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
  /// [redactedHeaders] — header names whose values are replaced with
  ///                  `'[REDACTED]'` in structured log output.  Defaults to a
  ///                  set of well-known sensitive headers (Authorization,
  ///                  Cookie, etc.).  Pass an empty set to disable redaction.
  /// [logHeaders]   — when `true` **and** [structured] is also `true`, request
  ///                  headers are included in the structured log entry (with
  ///                  redaction applied).  Defaults to `false`.
  LoggingHandler({
    Logger? logger,
    String Function(Uri)? uriSanitizer,
    bool structured = false,
    Set<String>? redactedHeaders,
    bool logHeaders = false,
  })  : _logger = logger ?? Logger('davianspace.http'),
        _uriSanitizer = uriSanitizer ?? _defaultSanitizer,
        _structured = structured,
        _redactedHeaders = redactedHeaders ?? _defaultRedactedHeaders,
        _logHeaders = logHeaders;

  final Logger _logger;
  final String Function(Uri) _uriSanitizer;
  final bool _structured;
  final Set<String> _redactedHeaders;
  final bool _logHeaders;

  /// Well-known headers that carry credentials or tokens.
  static const Set<String> _defaultRedactedHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
  };

  static String _defaultSanitizer(Uri uri) =>
      uri.replace(queryParameters: const {}).toString();

  @override
  Future<HttpResponse> send(HttpContext context) async {
    final req = context.request;
    final uriLabel = _uriSanitizer(req.uri);

    if (_structured) {
      final entry = <String, Object>{
        'event': 'request',
        'method': req.method.value,
        'uri': uriLabel,
      };
      if (_logHeaders && req.headers.isNotEmpty) {
        entry['headers'] = _redactHeaders(req.headers);
      }
      _logger.info(jsonEncode(entry));
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
            'error': _sanitizeError(e),
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

  /// Truncates the error description to prevent PII / large stack traces from
  /// being serialised into structured log output.
  static String _sanitizeError(Object error) {
    final s = error.runtimeType.toString();
    final msg = error.toString();
    // Limit to 256 chars — enough for diagnosis without leaking large bodies.
    return msg.length <= 256 ? '$s: $msg' : '$s: ${msg.substring(0, 256)}…';
  }

  /// Returns a copy of [headers] with values of sensitive header names
  /// replaced by `'[REDACTED]'`.
  Map<String, String> _redactHeaders(Map<String, String> headers) {
    return headers.map((name, value) {
      final redacted = _redactedHeaders.contains(name.toLowerCase());
      return MapEntry(name, redacted ? '[REDACTED]' : value);
    });
  }
}
