// Tests for LoggingHandler(structured: true) added in Phase 6.2.
// All log capture is done via the `davianspace_logging` package.

import 'dart:convert';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:davianspace_logging/davianspace_logging.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
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

({MemoryLogStore store, Logger logger}) _makeLogger() {
  final store = MemoryLogStore();
  final factory = LoggingBuilder().addMemory(store: store).build();
  return (store: store, logger: factory.createLogger('test.logging'));
}

http.Client _respondWith(int status, {String body = 'ok'}) =>
    http_testing.MockClient((_) async => http.Response(body, status));

http.Client _alwaysThrows(Object error) =>
    http_testing.MockClient((_) async => throw error);

// ════════════════════════════════════════════════════════════════════════════
//  Structured = false (default)
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('LoggingHandler — structured=false (default)', () {
    late MemoryLogStore store;
    late Logger logger;

    setUp(() {
      final r = _makeLogger();
      store = r.store;
      logger = r.logger;
    });

    test('request log starts with →', () async {
      final client = _buildLoggingClient(_respondWith(200), logger: logger);
      await client.get(Uri.parse('/path'));
      expect(store.events.any((e) => e.message.startsWith('→')), isTrue);
    });

    test('response log starts with ←', () async {
      final client = _buildLoggingClient(_respondWith(200), logger: logger);
      await client.get(Uri.parse('/path'));
      expect(store.events.any((e) => e.message.startsWith('←')), isTrue);
    });

    test('error log is not JSON', () async {
      final client = _buildLoggingClient(
        _alwaysThrows(Exception('boom')),
        logger: logger,
      );
      await expectLater(client.get(Uri.parse('/fail')), throwsException);
      final errorEvent = store.events.firstWhere(
        (e) => e.level.isAtLeast(LogLevel.error),
        orElse: () => throw StateError('no error event'),
      );
      expect(() => jsonDecode(errorEvent.message), throwsFormatException);
    });

    test('query parameters are stripped from URI by default', () async {
      final client = _buildLoggingClient(_respondWith(200), logger: logger);
      await client.get(Uri.parse('/search?secret=abc&key=xyz'));
      final requestEvent =
          store.events.firstWhere((e) => e.message.startsWith('→'));
      expect(requestEvent.message, isNot(contains('secret')));
      expect(requestEvent.message, isNot(contains('xyz')));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Structured = true
  // ──────────────────────────────────────────────────────────────────────────

  group('LoggingHandler — structured=true', () {
    late MemoryLogStore store;
    late Logger logger;

    setUp(() {
      final r = _makeLogger();
      store = r.store;
      logger = r.logger;
    });

    // ── Request ──────────────────────────────────────────────────────────────

    test('request emits valid JSON with event="request"', () async {
      final client = _buildLoggingClient(
        _respondWith(200),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/path'));

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"request"'));
      final json = jsonDecode(event.message) as Map<String, dynamic>;
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

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"request"'));
      final json = jsonDecode(event.message) as Map<String, dynamic>;
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

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"response"'));
      final json = jsonDecode(event.message) as Map<String, dynamic>;
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

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"response"'));
      final json = jsonDecode(event.message) as Map<String, dynamic>;
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

      final event =
          store.events.firstWhere((e) => e.message.contains('"event":"error"'));
      final json = jsonDecode(event.message) as Map<String, dynamic>;
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

      final event =
          store.events.firstWhere((e) => e.message.contains('"event":"error"'));
      final json = jsonDecode(event.message) as Map<String, dynamic>;
      expect(json, contains('uri'));
    });

    // ── Level mapping ─────────────────────────────────────────────────────────

    test('4xx response logged at warning level', () async {
      final client = _buildLoggingClient(
        _respondWith(404),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/missing'));

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"response"'));
      expect(event.level, LogLevel.warning);
    });

    test('5xx response logged at error level', () async {
      final client = _buildLoggingClient(
        _respondWith(500),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/broken'));

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"response"'));
      expect(event.level, LogLevel.error);
    });

    test('2xx response logged at info level', () async {
      final client = _buildLoggingClient(
        _respondWith(200),
        logger: logger,
        structured: true,
      );
      await client.get(Uri.parse('/ok'));

      final event = store.events
          .firstWhere((e) => e.message.contains('"event":"response"'));
      expect(event.level, LogLevel.info);
    });
  });
}
