// Tests for HttpResponse streaming support and related extension helpers.

import 'dart:async';
import 'dart:convert';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

Stream<List<int>> _streamOf(String text) => Stream.value(utf8.encode(text));

Stream<List<int>> _chunkedStream(String text, {int chunkSize = 2}) async* {
  final bytes = utf8.encode(text);
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, bytes.length);
    yield bytes.sublist(i, end);
  }
}

ResilientHttpClient _streamingClient(http.Client inner) => HttpClientBuilder()
    .withBaseUri(Uri.parse('https://example.com'))
    .withHttpClient(inner)
    .withStreamingMode()
    .build();

ResilientHttpClient _bufferedClient(http.Client inner) => HttpClientBuilder()
    .withBaseUri(Uri.parse('https://example.com'))
    .withHttpClient(inner)
    .build();

http.Client _mockTextClient(String body, {int status = 200}) =>
    http_testing.MockClient(
      (_) async => http.Response(body, status),
    );

// ════════════════════════════════════════════════════════════════════════════
//  HttpResponse — buffered mode (regression)
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('HttpResponse — buffered (default)', () {
    test('isStreaming is false', () {
      final r = HttpResponse(statusCode: 200);
      expect(r.isStreaming, isFalse);
    });

    test('body is accessible directly', () {
      final r = HttpResponse(statusCode: 200, body: utf8.encode('hello'));
      expect(r.body, isNotNull);
    });

    test('bodyStream wraps body bytes in a single-event stream', () async {
      final bytes = utf8.encode('hello');
      final r = HttpResponse(statusCode: 200, body: bytes);
      final collected = await r.bodyStream.toList();
      expect(collected.expand((c) => c).toList(), bytes);
    });

    test('bodyStream of null body emits empty list', () async {
      final r = HttpResponse(statusCode: 204);
      final chunks = await r.bodyStream.toList();
      expect(chunks.expand((c) => c).toList(), isEmpty);
    });

    test('toBuffered() returns same instance for buffered response', () async {
      final r = HttpResponse(statusCode: 200, body: utf8.encode('x'));
      expect(await r.toBuffered(), same(r));
    });

    test('toString describes size in bytes', () {
      final r = HttpResponse(statusCode: 200, body: [1, 2, 3]);
      expect(r.toString(), contains('3B'));
      expect(r.toString(), isNot(contains('streaming')));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  HttpResponse.streaming constructor
  // ──────────────────────────────────────────────────────────────────────────

  group('HttpResponse.streaming constructor', () {
    test('isStreaming is true', () {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('hello'),
      );
      expect(r.isStreaming, isTrue);
    });

    test('body is null for streaming response', () {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('data'),
      );
      expect(r.body, isNull);
    });

    test('bodyStream returns the live stream', () async {
      const text = 'hello world';
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf(text),
      );
      final bytes = await r.bodyStream.toList();
      expect(utf8.decode(bytes.expand((c) => c).toList()), text);
    });

    test('toString shows "streaming"', () {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('x'),
      );
      expect(r.toString(), contains('streaming'));
    });

    test('statusCode and headers are available immediately', () {
      final r = HttpResponse.streaming(
        statusCode: 201,
        headers: {'content-type': 'application/octet-stream'},
        bodyStream: _streamOf(''),
      );
      expect(r.statusCode, 201);
      expect(r.headers['content-type'], 'application/octet-stream');
    });

    test('isSuccess/isClientError/isServerError still work', () {
      expect(
        HttpResponse.streaming(statusCode: 200, bodyStream: _streamOf(''))
            .isSuccess,
        isTrue,
      );
      expect(
        HttpResponse.streaming(statusCode: 404, bodyStream: _streamOf(''))
            .isClientError,
        isTrue,
      );
      expect(
        HttpResponse.streaming(statusCode: 503, bodyStream: _streamOf(''))
            .isServerError,
        isTrue,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  toBuffered()
  // ──────────────────────────────────────────────────────────────────────────

  group('HttpResponse.toBuffered()', () {
    test('consumes stream into body bytes', () async {
      const text = 'hello world';
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf(text),
      );
      final buffered = await r.toBuffered();
      expect(buffered.isStreaming, isFalse);
      expect(utf8.decode(buffered.body!), text);
    });

    test('preserves metadata (statusCode, headers, duration)', () async {
      final r = HttpResponse.streaming(
        statusCode: 201,
        headers: {'x-custom': 'val'},
        bodyStream: _streamOf('x'),
        duration: const Duration(milliseconds: 42),
      );
      final buffered = await r.toBuffered();
      expect(buffered.statusCode, 201);
      expect(buffered.headers['x-custom'], 'val');
      expect(buffered.duration, const Duration(milliseconds: 42));
    });

    test('handles chunked stream correctly', () async {
      const text = 'abcdefghij';
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _chunkedStream(text, chunkSize: 3),
      );
      final buffered = await r.toBuffered();
      expect(utf8.decode(buffered.body!), text);
    });

    test('handles empty stream', () async {
      final r = HttpResponse.streaming(
        statusCode: 204,
        bodyStream: const Stream.empty(),
      );
      final buffered = await r.toBuffered();
      expect(buffered.body, isEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Async extension helpers
  // ──────────────────────────────────────────────────────────────────────────

  group('HttpResponseExtensions — async helpers (buffered)', () {
    test('readAsString() works for buffered response', () async {
      final r = HttpResponse(statusCode: 200, body: utf8.encode('hello'));
      expect(await r.readAsString(), 'hello');
    });

    test('readAsJson() parses object', () async {
      final r = HttpResponse(
        statusCode: 200,
        body: utf8.encode('{"key":"value"}'),
      );
      final json = await r.readAsJson();
      expect(json, {'key': 'value'});
    });

    test('readAsJsonMap() returns typed map', () async {
      final r = HttpResponse(
        statusCode: 200,
        body: utf8.encode('{"n":1}'),
      );
      expect(await r.readAsJsonMap(), {'n': 1});
    });

    test('readAsJsonList() returns typed list', () async {
      final r = HttpResponse(statusCode: 200, body: utf8.encode('[1,2,3]'));
      expect(await r.readAsJsonList(), [1, 2, 3]);
    });
  });

  group('HttpResponseExtensions — async helpers (streaming)', () {
    test('readAsString() consumes stream', () async {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('streamed text'),
      );
      expect(await r.readAsString(), 'streamed text');
    });

    test('readAsJson() parses streaming JSON', () async {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('{"x":42}'),
      );
      expect(await r.readAsJson(), {'x': 42});
    });

    test('readAsJsonMap() works for streaming response', () async {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _chunkedStream('{"a":"b"}'),
      );
      expect(await r.readAsJsonMap(), {'a': 'b'});
    });

    test('readAsJsonList() works for streaming response', () async {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('[1,2,3]'),
      );
      expect(await r.readAsJsonList(), [1, 2, 3]);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  ensureSuccess with streaming
  // ──────────────────────────────────────────────────────────────────────────

  group('ensureSuccess with streaming response', () {
    test('passes for 2xx streaming response without consuming stream', () {
      final r = HttpResponse.streaming(
        statusCode: 200,
        bodyStream: _streamOf('ok'),
      );
      expect(r.ensureSuccess(), same(r));
    });

    test('throws HttpStatusException for 4xx streaming response', () {
      final r = HttpResponse.streaming(
        statusCode: 404,
        bodyStream: _streamOf('not found'),
      );
      expect(r.ensureSuccess, throwsA(isA<HttpStatusException>()));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  TerminalHandler — streaming mode via builder
  // ──────────────────────────────────────────────────────────────────────────

  group('HttpClientBuilder.withStreamingMode()', () {
    test('response isStreaming == true when streaming mode enabled', () async {
      final client = _streamingClient(_mockTextClient('data'));
      final response = await client.get(Uri.parse('/file'));
      expect(response.isStreaming, isTrue);
      expect(response.body, isNull);
    });

    test('body is accessible via readAsString on streaming response', () async {
      const text = 'important data';
      final client = _streamingClient(_mockTextClient(text));
      final response = await client.get(Uri.parse('/data'));
      expect(await response.readAsString(), text);
    });

    test('response body is null in streaming mode', () async {
      final client = _streamingClient(_mockTextClient('x'));
      final response = await client.get(Uri.parse('/x'));
      expect(response.body, isNull);
    });

    test('buffered mode is the default (isStreaming == false)', () async {
      final client = _bufferedClient(_mockTextClient('data'));
      final response = await client.get(Uri.parse('/data'));
      expect(response.isStreaming, isFalse);
      expect(response.body, isNotNull);
    });

    test('statusCode is correct in streaming mode', () async {
      final mockClient = http_testing.MockClient(
        (_) async => http.Response('', 201),
      );
      final client = _streamingClient(mockClient);
      final response = await client.post(Uri.parse('/items'), body: '{}');
      expect(response.statusCode, 201);
    });

    test('toBuffered() on a streamed response restores body bytes', () async {
      const text = 'enterprise streaming data';
      final client = _streamingClient(_mockTextClient(text));
      final streaming = await client.get(Uri.parse('/large'));
      final buffered = await streaming.toBuffered();
      expect(buffered.isStreaming, isFalse);
      expect(utf8.decode(buffered.body!), text);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  RetryHandler + streaming: status-based retry works (headers only)
  // ──────────────────────────────────────────────────────────────────────────

  group('RetryHandler compatibility with streaming mode', () {
    test('retries on 503 and returns streaming 200 on success', () async {
      var calls = 0;
      final mockClient = http_testing.MockClient((_) async {
        calls++;
        if (calls < 2) return http.Response('error', 503);
        return http.Response('ok', 200);
      });

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withHttpClient(mockClient)
          .withRetry(
            RetryPolicy.constant(
              maxRetries: 1,
              delay: Duration.zero,
              shouldRetry: (r, _, __) => r?.statusCode == 503,
            ),
          )
          .withStreamingMode()
          .build();

      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
      expect(response.isStreaming, isTrue);
      expect(calls, 2);
    });
  });
}
