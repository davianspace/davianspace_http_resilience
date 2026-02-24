import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

void main() {
  group('HttpRequest', () {
    test('constructs with required fields', () {
      final req = HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com/path'),
      );
      expect(req.method, HttpMethod.get);
      expect(req.uri.host, 'example.com');
      expect(req.headers, isEmpty);
      expect(req.body, isNull);
      expect(req.metadata, isEmpty);
    });

    test('copyWith replaces only specified fields', () {
      final original = HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
        headers: {'Accept': 'application/json'},
      );
      final copy = original.copyWith(method: HttpMethod.post);
      expect(copy.method, HttpMethod.post);
      expect(copy.uri, original.uri);
      expect(copy.headers['Accept'], 'application/json');
    });

    test('withHeader adds header without mutating original', () {
      final req = HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
      );
      final updated = req.withHeader('X-Trace', '123');
      expect(updated.headers['X-Trace'], '123');
      expect(req.headers, isEmpty);
    });

    test('headers and metadata are unmodifiable', () {
      final req = HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
        headers: {'Accept': 'application/json'},
      );
      expect(
        () => req.headers['New'] = 'value',
        throwsUnsupportedError,
      );
      expect(
        () => req.metadata['key'] = 'value',
        throwsUnsupportedError,
      );
    });

    test('builder constructs correctly', () {
      final req = HttpRequest.builder()
        ..method = HttpMethod.post
        ..uri = Uri.parse('https://example.com/items')
        ..setHeader('Content-Type', 'application/json')
        ..body = [1, 2, 3];
      final built = req.build();
      expect(built.method, HttpMethod.post);
      expect(built.headers['Content-Type'], 'application/json');
      expect(built.body, [1, 2, 3]);
    });

    test('builder throws StateError when uri is missing', () {
      expect(
        () => HttpRequest.builder().build(),
        throwsStateError,
      );
    });

    test('equality is value-based', () {
      final a = HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
      );
      final b = HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
      );
      expect(a, equals(b));
    });
  });

  group('HttpMethod', () {
    test('well-known methods are singletons', () {
      expect(identical(HttpMethod.get, HttpMethod.get), isTrue);
    });

    test('custom method normalises to uppercase', () {
      final m = HttpMethod.custom('purge');
      expect(m.value, 'PURGE');
    });

    test('equality compares by value', () {
      expect(HttpMethod.custom('GET'), equals(HttpMethod.get));
    });
  });
}
