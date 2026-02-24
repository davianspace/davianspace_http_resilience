import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

void main() {
  group('HttpResponse', () {
    test('isSuccess for 2xx', () {
      expect(const HttpResponse(statusCode: 200).isSuccess, isTrue);
      expect(const HttpResponse(statusCode: 201).isSuccess, isTrue);
      expect(const HttpResponse(statusCode: 299).isSuccess, isTrue);
    });

    test('isClientError for 4xx', () {
      expect(const HttpResponse(statusCode: 400).isClientError, isTrue);
      expect(const HttpResponse(statusCode: 404).isClientError, isTrue);
      expect(const HttpResponse(statusCode: 499).isClientError, isTrue);
    });

    test('isServerError for 5xx', () {
      expect(const HttpResponse(statusCode: 500).isServerError, isTrue);
      expect(const HttpResponse(statusCode: 503).isServerError, isTrue);
    });

    test('isRedirect for 3xx', () {
      expect(const HttpResponse(statusCode: 301).isRedirect, isTrue);
    });

    test('copyWith preserves unchanged fields', () {
      const original = HttpResponse(statusCode: 200, body: [1, 2]);
      final copy = original.copyWith(statusCode: 404);
      expect(copy.statusCode, 404);
      expect(copy.body, [1, 2]);
    });

    test('HttpResponse.ok factory returns 200', () {
      expect(HttpResponse.ok().statusCode, 200);
    });

    test('HttpResponse.serviceUnavailable factory returns 503', () {
      expect(HttpResponse.serviceUnavailable().statusCode, 503);
    });
  });

  group('HttpResponseExtensions', () {
    test('bodyAsString decodes UTF-8', () {
      final bytes = [72, 101, 108, 108, 111]; // "Hello"
      final response = HttpResponse(statusCode: 200, body: bytes);
      expect(response.bodyAsString, 'Hello');
    });

    test('bodyAsString returns empty for null body', () {
      expect(const HttpResponse(statusCode: 204).bodyAsString, isEmpty);
    });

    test('ensureSuccess returns self for 2xx', () {
      final r = HttpResponse.ok();
      expect(r.ensureSuccess(), same(r));
    });

    test('ensureSuccess throws HttpStatusException for non-2xx', () {
      const r = HttpResponse(statusCode: 404);
      expect(r.ensureSuccess, throwsA(isA<HttpStatusException>()));
    });
  });
}
