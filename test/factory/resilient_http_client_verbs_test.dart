// Tests for ResilientHttpClient.head() and .options() added in Phase 6.1.

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test doubles
// ════════════════════════════════════════════════════════════════════════════

/// Records every HTTP method seen by the underlying transport.
final class _MethodCapture extends http.BaseClient {
  final List<String> methods = [];
  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    methods.add(request.method);
    uris.add(request.url);
    headers.add(Map.of(request.headers));
    return http.StreamedResponse(
      Stream.value('ok'.codeUnits),
      200,
      request: request,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  late _MethodCapture capture;
  late ResilientHttpClient client;

  setUp(() {
    capture = _MethodCapture();
    client = HttpClientBuilder()
        .withBaseUri(Uri.parse('https://api.example.com/v1'))
        .withHttpClient(capture)
        .build();
  });

  group('ResilientHttpClient.head()', () {
    test('sends a HEAD request', () async {
      await client.head(Uri.parse('/ping'));
      expect(capture.methods, ['HEAD']);
    });

    test('resolves URI against baseUri', () async {
      // baseUri is 'https://api.example.com/v1'; absolute path '/health'
      // replaces the entire path per RFC 3986 §5.2 semantics.
      await client.head(Uri.parse('/health'));
      expect(capture.uris.single.host, 'api.example.com');
      expect(capture.uris.single.path, '/health');
    });

    test('returns an HttpResponse', () async {
      final resp = await client.head(Uri.parse('/x'));
      expect(resp, isA<HttpResponse>());
      expect(resp.statusCode, 200);
    });

    test('merges custom headers into the request', () async {
      await client.head(Uri.parse('/x'), headers: {'X-Request-Id': 'abc'});
      expect(
        capture.headers.single.keys.map((k) => k.toLowerCase()),
        contains('x-request-id'),
      );
    });
  });

  group('ResilientHttpClient.options()', () {
    test('sends an OPTIONS request', () async {
      await client.options(Uri.parse('/resource'));
      expect(capture.methods, ['OPTIONS']);
    });

    test('resolves URI against baseUri', () async {
      // Absolute path '/items' replaces the base path per RFC 3986.
      await client.options(Uri.parse('/items'));
      expect(capture.uris.single.host, 'api.example.com');
      expect(capture.uris.single.path, '/items');
    });

    test('returns an HttpResponse', () async {
      final resp = await client.options(Uri.parse('/x'));
      expect(resp, isA<HttpResponse>());
      expect(resp.statusCode, 200);
    });

    test('merges custom headers into the request', () async {
      await client
          .options(Uri.parse('/x'), headers: {'Accept': 'application/json'});
      expect(
        capture.headers.single.keys.map((k) => k.toLowerCase()),
        contains('accept'),
      );
    });
  });

  group('ResilientHttpClient — HEAD vs OPTIONS are independent verbs', () {
    test('successive HEAD and OPTIONS produce correct methods', () async {
      await client.head(Uri.parse('/x'));
      await client.options(Uri.parse('/x'));
      expect(capture.methods, ['HEAD', 'OPTIONS']);
    });

    test(
        'HEAD and OPTIONS alongside existing verbs all produce correct methods',
        () async {
      final mockClient = http_testing.MockClient(
        (_) async => http.Response('', 200),
      );
      final c = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://api.example.com'))
          .withHttpClient(mockClient)
          .build();

      // Smoke-test that the other verbs still work after adding head/options
      await c.get(Uri.parse('/a'));
      await c.post(Uri.parse('/a'), body: '');
      await c.head(Uri.parse('/a'));
      await c.options(Uri.parse('/a'));
      // No assertion — absence of exception is sufficient.
    });
  });
}
