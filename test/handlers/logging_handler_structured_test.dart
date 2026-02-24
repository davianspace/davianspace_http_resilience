// Tests for LoggingHandler(structured: true) added in Phase 6.2.
// All log capture is done via the `logging` package.

import 'dart:convert';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Builds a [ResilientHttpClient] with a [LoggingHandler] wired in front of
/// the supplied [inner] http.Client.
ResilientHttpClient _buildLoggingClient(
  http.Client inner, {
  required Logger logger,
  bool structured = false,
}) =>
    HttpClientBuilder()
        .withBaseUri(Uri.parse('https://example.com'))
        .addHandler(LoggingHandler(logger: logger, structured: structured))
        .withHttpClient(inner)
        .build();

Logger _uniqueLogger() =>
    Logger('test.logging.${DateTime.now().microsecondsSinceEpoch}');

http.Client _respondWith(int status, {String body = 'ok'}) =>
    http_testing.MockClient((_) async => http.Response(body, status));

http.Client _alwaysThrows(Object error) =>
    http_testing.MockClient((_) async => throw error);

// ════════════════════════════════════════════════════════════════════════════
//  Structured = false (default)
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('LoggingHandler — structured=false (default)', () {
    late List<LogRecord> records;
    late Logger logger;

    setUp(() {
      records = [];
      logger = _uniqueLogger();
      logger.onRecord.listen(records.add);
    });

    test('request log starts with →', () async {
      final client = _buildLoggingClient(_respondWith(200), logger: logger);
      await client.get(Uri.parse('/path'));
      expect(records.any((r) => r.message.startsWith('→')), isTrue);
    });

    test('response log starts with ←', () async {
      final client = _buildLoggingClient(_respondWith(200), logger: logger);
      await client.get(Uri.parse('/path'));
      expect(records.any((r) => r.message.startsWith('←')), isTrue);
    });

    test('error log is not JSON', () async {
      final client = _buildLoggingClient(
        _alwaysThrows(Exception('boom')),
        logger: logger,
      );
      await expectLater(client.get(Uri.parse('/fail')), throwsException);
      final errorRecord = records.firstWhere(
        (r) => r.level >= Level.SEVERE,
        orElse: () => throw StateError('no severe record'),
      );
      expect(() => jsonDecode(errorRecord.message), throwsFormatException);
    });

    test('query parameters are stripped from URI by default', () async {
      final client = _buildLoggingClient(_respondWith(200), logger: logger);
      await client.get(Uri.parse('/search?secret=abc&key=xyz'));
      final requestRecord =
          records.firstWhere((r) => r.message.startsWith('→'));
      expect(requestRecord.message, isNot(contains('secret')));
      expect(requestRecord.message, isNot(contains('xyz')));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Structured = true
  // ──────────────────────────────────────────────────────────────────────────

  group('LoggingHandler — structured=true', () {
    late List<LogRecord> records;
    late Logger logger;

    setUp(() {
      records = [];
      logger = _uniqueLogger();
      logger.onRecord.listen(records.add);
    });

    // ── Request ──────────────────────────────────────────────────────────────

    test('request emits valid JSON with event="request"', () async {
      final client = _buildLoggingClient(
        _respondWith(200),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/path'));

      final record =
          records.firstWhere((r) => r.message.contains('"event":"request"'));
      final json = jsonDecode(record.message) as Map<String, dynamic>;
      expect(json['event'], 'request');
      expect(json['method'], 'GET');
      expect(json['uri'], isA<String>());
    });

    test('request JSON strips query params from URI', () async {
      final client = _buildLoggingClient(
        _respondWith(200),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/search?token=secret'));

      final record =
          records.firstWhere((r) => r.message.contains('"event":"request"'));
      final json = jsonDecode(record.message) as Map<String, dynamic>;
      expect(json['uri'] as String, isNot(contains('secret')));
    });

    // ── Response ─────────────────────────────────────────────────────────────

    test('response emits valid JSON with event="response"', () async {
      final client = _buildLoggingClient(
        _respondWith(201),
        logger: logger,
        structured: true,
      );
      await client.post(Uri.parse('/items'), body: '{}');

      final record =
          records.firstWhere((r) => r.message.contains('"event":"response"'));
      final json = jsonDecode(record.message) as Map<String, dynamic>;
      expect(json['event'], 'response');
      expect(json['status'], 201);
      expect(json['method'], 'POST');
      expect(json['durationMs'], isA<int>());
      expect(json['retryCount'], 0);
    });

    test('response JSON contains uri field', () async {
      final client = _buildLoggingClient(
        _respondWith(200),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/items'));

      final record =
          records.firstWhere((r) => r.message.contains('"event":"response"'));
      final json = jsonDecode(record.message) as Map<String, dynamic>;
      expect(json, contains('uri'));
    });

    // ── Error ────────────────────────────────────────────────────────────────

    test('exception emits valid JSON with event="error"', () async {
      final client = _buildLoggingClient(
        _alwaysThrows(Exception('network-failure')),
        logger: logger,
        structured: true,
      );
      await expectLater(client.get(Uri.parse('/fail')), throwsException);

      final record =
          records.firstWhere((r) => r.message.contains('"event":"error"'));
      final json = jsonDecode(record.message) as Map<String, dynamic>;
      expect(json['event'], 'error');
      expect(json['method'], 'GET');
      expect(json['durationMs'], isA<int>());
      expect(json['error'], isA<String>());
    });

    test('error JSON contains uri field', () async {
      final client = _buildLoggingClient(
        _alwaysThrows(Exception('boom')),
        logger: logger,
        structured: true,
      );
      await expectLater(client.get(Uri.parse('/fail')), throwsException);

      final record =
          records.firstWhere((r) => r.message.contains('"event":"error"'));
      final json = jsonDecode(record.message) as Map<String, dynamic>;
      expect(json, contains('uri'));
    });

    // ── Level mapping ─────────────────────────────────────────────────────────

    test('4xx response logged at WARNING level', () async {
      final client = _buildLoggingClient(
        _respondWith(404),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/missing'));

      final record =
          records.firstWhere((r) => r.message.contains('"event":"response"'));
      expect(record.level, Level.WARNING);
    });

    test('5xx response logged at SEVERE level', () async {
      final client = _buildLoggingClient(
        _respondWith(500),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/broken'));

      final record =
          records.firstWhere((r) => r.message.contains('"event":"response"'));
      expect(record.level, Level.SEVERE);
    });

    test('2xx response logged at INFO level', () async {
      final client = _buildLoggingClient(
        _respondWith(200),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/ok'));

      final record =
          records.firstWhere((r) => r.message.contains('"event":"response"'));
      expect(record.level, Level.INFO);
    });
  });
}
