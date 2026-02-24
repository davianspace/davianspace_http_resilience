import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test helpers
// ════════════════════════════════════════════════════════════════════════════

/// A simple typed service client backed by a [ResilientHttpClient].
final class _UserService {
  _UserService(this.client);
  final ResilientHttpClient client;
  Future<HttpResponse> getUser(int id) => client.get(Uri.parse('/users/$id'));
}

/// Another typed service for multi-typed-client tests.
final class _ProductService {
  _ProductService(this.client);
  final ResilientHttpClient client;
}

/// Returns an [http_testing.MockClient] that always returns [statusCode] with
/// [body].
http.Client _mockClient({int statusCode = 200, String body = 'OK'}) =>
    http_testing.MockClient(
      (_) async => http.Response(body, statusCode),
    );

/// Returns an [http_testing.MockClient] that tracks the number of calls.
final class _CallCountingClient extends http.BaseClient {
  int callCount = 0;
  final List<Map<String, String>> capturedHeaders = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    callCount++;
    // Normalise to lowercase — HTTP header names are case-insensitive and
    // most real transports lowercase them before delivery.
    capturedHeaders.add({
      for (final entry in request.headers.entries)
        entry.key.toLowerCase(): entry.value,
    });
    final bytes = 'call $callCount'.codeUnits;
    return http.StreamedResponse(
      Stream.value(bytes),
      200,
      request: request,
    );
  }
}

// A [ResiliencePolicy] that counts how many times it wraps execution.
final class _CountingPolicy extends ResiliencePolicy {
  int executions = 0;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    executions++;
    return action();
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientBuilder', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('build() returns a ResilientHttpClient', () {
      final client = HttpClientBuilder().withHttpClient(_mockClient()).build();
      expect(client, isA<ResilientHttpClient>());
    });

    test('withBaseUri resolves relative URIs', () async {
      final mockHttp = _CallCountingClient();
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://api.example.com'))
          .withHttpClient(mockHttp)
          .build();

      await client.get(Uri.parse('/users/1'));
      // The real HTTP client sees the absolute URI; we just verify no throw.
      expect(mockHttp.callCount, 1);
    });

    test('withDefaultHeader is sent with every request', () async {
      final mockHttp = _CallCountingClient();
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://api.example.com'))
          .withDefaultHeader('Accept', 'application/json')
          .withDefaultHeader('X-App-Version', '2.0')
          .withHttpClient(mockHttp)
          .build();

      await client.get(Uri.parse('/test'));
      final headers = mockHttp.capturedHeaders.first;
      expect(headers['accept'], 'application/json');
      expect(headers['x-app-version'], '2.0');
    });

    test('withPolicy wraps requests through the policy', () async {
      final policy = _CountingPolicy();
      final client = HttpClientBuilder()
          .withPolicy(policy)
          .withHttpClient(_mockClient())
          .withBaseUri(Uri.parse('https://example.com'))
          .build();

      await client.get(Uri.parse('/ping'));
      expect(policy.executions, 1);

      await client.post(Uri.parse('/items'), body: '{}');
      expect(policy.executions, 2);
    });

    test('two withPolicy calls both execute', () async {
      final outer = _CountingPolicy();
      final inner = _CountingPolicy();

      final client = HttpClientBuilder()
          .withPolicy(outer)
          .withPolicy(inner)
          .withHttpClient(_mockClient())
          .withBaseUri(Uri.parse('https://example.com'))
          .build();

      await client.get(Uri.parse('/ping'));
      expect(outer.executions, 1);
      expect(inner.executions, 1);
    });

    test('withPolicy(PolicyWrap) applies composite policy', () async {
      final a = _CountingPolicy();
      final b = _CountingPolicy();
      final composed = Policy.wrap([a, b]);

      final client = HttpClientBuilder()
          .withPolicy(composed)
          .withHttpClient(_mockClient())
          .withBaseUri(Uri.parse('https://example.com'))
          .build();

      await client.get(Uri.parse('/ping'));
      expect(a.executions, 1);
      expect(b.executions, 1);
    });

    test('build() can be called multiple times, each with fresh pipeline', () {
      final builder = HttpClientBuilder().withHttpClient(_mockClient());
      final c1 = builder.build();
      final c2 = builder.build();
      expect(c1, isNot(same(c2)));
    });

    test('toString() includes handler count', () {
      final s = HttpClientBuilder()
          .withPolicy(_CountingPolicy())
          .withPolicy(_CountingPolicy())
          .toString();
      expect(s, contains('2 handler(s)'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyHandler', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('sends request through inner handler', () async {
      final mock = _mockClient(body: 'hello');
      final client = HttpClientBuilder()
          .withHttpClient(mock)
          .withBaseUri(Uri.parse('https://example.com'))
          .withPolicy(_CountingPolicy())
          .build();

      final response = await client.get(Uri.parse('/test'));
      expect(response.statusCode, 200);
    });

    test('policy is consulted even for non-throwing 500 responses', () async {
      // A 500 is a valid HTTP response — no Dart exception is thrown.
      // The policy is still invoked once and the response is returned as-is.
      final mock = _mockClient(statusCode: 500);
      final counting = _CountingPolicy();
      final client = HttpClientBuilder()
          .withPolicy(counting)
          .withHttpClient(mock)
          .withBaseUri(Uri.parse('https://example.com'))
          .build();

      final resp = await client.get(Uri.parse('/fail'));
      expect(resp.statusCode, 500);
      expect(counting.executions, 1);
    });

    test('retry policy retries on exception inside pipeline', () async {
      var callCount = 0;
      final mockHttp = http_testing.MockClient((_) async {
        callCount++;
        if (callCount < 3) throw Exception('transient');
        return http.Response('ok', 200);
      });

      final client = HttpClientBuilder()
          .withPolicy(Policy.retry(maxRetries: 3))
          .withHttpClient(mockHttp)
          .withBaseUri(Uri.parse('https://example.com'))
          .build();

      final resp = await client.get(Uri.parse('/items'));
      expect(resp.statusCode, 200);
      expect(callCount, 3);
    });

    test('toString() shows policy type', () {
      final p = PolicyHandler(Policy.retry(maxRetries: 1));
      expect(p.toString(), contains('PolicyHandler'));
      expect(p.toString(), contains('RetryResiliencePolicy'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — named clients', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;

    setUp(() => factory = HttpClientFactory());
    tearDown(() => factory.clear());

    test('addClient registers and createClient returns a ResilientHttpClient',
        () {
      factory.addClient(
        'api',
        (b) => b.withHttpClient(_mockClient()),
      );
      final client = factory.createClient('api');
      expect(client, isA<ResilientHttpClient>());
    });

    test('createClient returns the same cached instance on repeated calls', () {
      factory.addClient('api', (b) => b.withHttpClient(_mockClient()));
      final c1 = factory.createClient('api');
      final c2 = factory.createClient('api');
      expect(c1, same(c2));
    });

    test('different names produce independent instances', () {
      factory
        ..addClient('service-a', (b) => b.withHttpClient(_mockClient()))
        ..addClient('service-b', (b) => b.withHttpClient(_mockClient()));

      final a = factory.createClient('service-a');
      final b = factory.createClient('service-b');
      expect(a, isNot(same(b)));
    });

    test('multiple addClient calls with same name layer configurators',
        () async {
      final mockHttp = _CallCountingClient();

      factory
        ..addClient(
            'api', (b) => b.withBaseUri(Uri.parse('https://api.example.com')),)
        ..addClient('api', (b) => b.withDefaultHeader('X-Version', '3'))
        ..addClient('api', (b) => b.withHttpClient(mockHttp));

      final client = factory.createClient('api');
      await client.get(Uri.parse('/resource'));

      // All three configurators applied: base URI is set, header added, mock injected.
      expect(mockHttp.callCount, 1);
      expect(mockHttp.capturedHeaders.first['x-version'], '3');
    });

    test('createClient(no args) resolves the default (empty-name) client', () {
      // No explicit registration needed; defaults are used.
      final client = factory.createClient();
      expect(client, isA<ResilientHttpClient>());
      // Repeated calls return the same instance.
      expect(factory.createClient(), same(client));
    });

    test('createClient throws StateError for unknown non-empty name', () {
      expect(
        () => factory.createClient('unknown'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unknown'),
          ),
        ),
      );
    });

    test('hasClient returns correct values before and after registration', () {
      expect(factory.hasClient('svc'), isFalse);
      factory.addClient('svc', (b) => b.withHttpClient(_mockClient()));
      expect(factory.hasClient('svc'), isTrue);
    });

    test('registeredNames reflects all addClient registrations', () {
      factory
        ..addClient('alpha', (b) => b.withHttpClient(_mockClient()))
        ..addClient('beta', (b) => b.withHttpClient(_mockClient()));
      expect(factory.registeredNames, containsAll(['alpha', 'beta']));
    });

    test('registeredNames is unmodifiable', () {
      factory.addClient('x', (b) => b.withHttpClient(_mockClient()));
      expect(
        () => factory.registeredNames.add('y'),
        throwsUnsupportedError,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — default configuration', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;

    setUp(() => factory = HttpClientFactory());
    tearDown(() => factory.clear());

    test('configureDefaults header appears on all named clients', () async {
      factory.configureDefaults(
        (b) => b.withDefaultHeader('X-Global', 'true'),
      );

      final mockA = _CallCountingClient();
      final mockB = _CallCountingClient();

      factory
        ..addClient(
            'alpha',
            (b) => b
                .withBaseUri(Uri.parse('https://alpha.example.com'))
                .withHttpClient(mockA),)
        ..addClient(
            'beta',
            (b) => b
                .withBaseUri(Uri.parse('https://beta.example.com'))
                .withHttpClient(mockB),);

      await factory.createClient('alpha').get(Uri.parse('/ping'));
      await factory.createClient('beta').get(Uri.parse('/ping'));

      expect(mockA.capturedHeaders.first['x-global'], 'true');
      expect(mockB.capturedHeaders.first['x-global'], 'true');
    });

    test('per-client header overrides default header with same name', () async {
      final mockHttp = _CallCountingClient();
      factory
        ..configureDefaults((b) => b.withDefaultHeader('Accept', 'text/plain'))
        ..addClient(
            'api',
            (b) => b
                .withHttpClient(mockHttp)
                .withBaseUri(Uri.parse('https://api.example.com'))
                .withDefaultHeader('Accept', 'application/json'),);

      await factory.createClient('api').get(Uri.parse('/resource'));
      expect(mockHttp.capturedHeaders.first['accept'], 'application/json');
    });

    test('multiple configureDefaults calls all apply', () async {
      final mockHttp = _CallCountingClient();
      factory
        ..configureDefaults((b) => b.withDefaultHeader('X-Hdr1', 'a'))
        ..configureDefaults((b) => b.withDefaultHeader('X-Hdr2', 'b'))
        ..addClient(
            'api',
            (b) => b
                .withHttpClient(mockHttp)
                .withBaseUri(Uri.parse('https://api.example.com')),);

      await factory.createClient('api').get(Uri.parse('/resource'));
      final h = mockHttp.capturedHeaders.first;
      expect(h['x-hdr1'], 'a');
      expect(h['x-hdr2'], 'b');
    });

    test('configureDefaults after addClient invalidates cached client', () {
      factory.addClient('api', (b) => b.withHttpClient(_mockClient()));
      final first = factory.createClient('api'); // builds and caches

      factory.configureDefaults((b) => b.withDefaultHeader('X-New', '1'));
      final second = factory.createClient('api'); // must rebuild

      expect(first, isNot(same(second)));
    });

    test('default policy is applied to all clients', () async {
      final policy = _CountingPolicy();
      factory.configureDefaults((b) => b.withPolicy(policy));

      final mockA = _mockClient();
      final mockB = _mockClient();

      factory
        ..addClient(
            'a',
            (b) => b
                .withHttpClient(mockA)
                .withBaseUri(Uri.parse('https://a.example.com')),)
        ..addClient(
            'b',
            (b) => b
                .withHttpClient(mockB)
                .withBaseUri(Uri.parse('https://b.example.com')),);

      await factory.createClient('a').get(Uri.parse('/ping'));
      await factory.createClient('b').get(Uri.parse('/ping'));

      expect(policy.executions, 2);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — typed clients', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;

    setUp(() => factory = HttpClientFactory());
    tearDown(() => factory.clear());

    test('addTypedClient + createTypedClient return the typed service', () {
      factory.addTypedClient<_UserService>(
        _UserService.new,
        clientName: 'users',
        configure: (b) => b
            .withHttpClient(_mockClient())
            .withBaseUri(Uri.parse('https://users.svc')),
      );

      final service = factory.createTypedClient<_UserService>();
      expect(service, isA<_UserService>());
    });

    test('createTypedClient returns the same cached instance', () {
      factory.addTypedClient<_UserService>(
        _UserService.new,
        clientName: 'users',
        configure: (b) => b.withHttpClient(_mockClient()),
      );

      final s1 = factory.createTypedClient<_UserService>();
      final s2 = factory.createTypedClient<_UserService>();
      expect(s1, same(s2));
    });

    test('typed client executes HTTP requests through the pipeline', () async {
      final mockHttp = _CallCountingClient();
      factory.addTypedClient<_UserService>(
        _UserService.new,
        clientName: 'users',
        configure: (b) => b
            .withHttpClient(mockHttp)
            .withBaseUri(Uri.parse('https://users.svc')),
      );

      final service = factory.createTypedClient<_UserService>();
      await service.getUser(42);

      expect(mockHttp.callCount, 1);
    });

    test('two different typed clients are independent', () {
      factory
        ..addTypedClient<_UserService>(
          _UserService.new,
          clientName: 'users',
          configure: (b) => b.withHttpClient(_mockClient()),
        )
        ..addTypedClient<_ProductService>(
          _ProductService.new,
          clientName: 'products',
          configure: (b) => b.withHttpClient(_mockClient()),
        );

      final users = factory.createTypedClient<_UserService>();
      final products = factory.createTypedClient<_ProductService>();

      expect(users, isA<_UserService>());
      expect(products, isA<_ProductService>());
    });

    test('typed client can share an underlying named client', () {
      factory.addClient(
        'shared',
        (b) => b.withHttpClient(_mockClient()),
      );

      factory
        ..addTypedClient<_UserService>(
          _UserService.new,
          clientName: 'shared',
        )
        ..addTypedClient<_ProductService>(
          _ProductService.new,
          clientName: 'shared',
        );

      final users = factory.createTypedClient<_UserService>();
      final products = factory.createTypedClient<_ProductService>();

      // Both are distinct typed services but share the same underlying
      // ResilientHttpClient instance.
      expect(users.client, same(products.client));
    });

    test('typed client without clientName uses the default client', () {
      factory.addTypedClient<_UserService>(
        _UserService.new,
        configure: (b) => b.withHttpClient(_mockClient()),
        // clientName omitted → uses ''
      );
      final service = factory.createTypedClient<_UserService>();
      expect(service, isA<_UserService>());
    });

    test('createTypedClient throws StateError for unregistered type', () {
      expect(
        () => factory.createTypedClient<_UserService>(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('_UserService'),
          ),
        ),
      );
    });

    test('registeredTypes reflects all addTypedClient registrations', () {
      factory
        ..addTypedClient<_UserService>(
          _UserService.new,
          configure: (b) => b.withHttpClient(_mockClient()),
        )
        ..addTypedClient<_ProductService>(
          _ProductService.new,
          configure: (b) => b.withHttpClient(_mockClient()),
        );

      expect(factory.registeredTypes,
          containsAll([_UserService, _ProductService]),);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — cache invalidation', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;

    setUp(() => factory = HttpClientFactory());
    tearDown(() => factory.clear());

    test('invalidate(name) forces named client rebuild', () {
      factory.addClient('svc', (b) => b.withHttpClient(_mockClient()));
      final c1 = factory.createClient('svc');

      factory.invalidate('svc');
      final c2 = factory.createClient('svc');

      expect(c1, isNot(same(c2)));
    });

    test('invalidate(name) does not affect other named clients', () {
      factory
        ..addClient('a', (b) => b.withHttpClient(_mockClient()))
        ..addClient('b', (b) => b.withHttpClient(_mockClient()));

      final a = factory.createClient('a');
      final b = factory.createClient('b');

      factory.invalidate('a');

      final a2 = factory.createClient('a');
      final b2 = factory.createClient('b');

      expect(a2, isNot(same(a)));
      expect(b2, same(b)); // 'b' untouched
    });

    test('invalidate() with no arg rebuilds all named clients', () {
      factory
        ..addClient('x', (b) => b.withHttpClient(_mockClient()))
        ..addClient('y', (b) => b.withHttpClient(_mockClient()));

      final x1 = factory.createClient('x');
      final y1 = factory.createClient('y');

      factory.invalidate();

      expect(factory.createClient('x'), isNot(same(x1)));
      expect(factory.createClient('y'), isNot(same(y1)));
    });

    test('invalidate(name) also invalidates typed clients backed by that name',
        () {
      factory.addTypedClient<_UserService>(
        _UserService.new,
        clientName: 'users',
        configure: (b) => b.withHttpClient(_mockClient()),
      );

      final s1 = factory.createTypedClient<_UserService>();

      factory.invalidate('users');

      final s2 = factory.createTypedClient<_UserService>();
      expect(s1, isNot(same(s2)));
    });

    test('adding a new configurator to an existing name invalidates cache', () {
      factory.addClient('svc', (b) => b.withHttpClient(_mockClient()));
      final c1 = factory.createClient('svc');

      // Adding another configurator must bust the cache.
      factory.addClient('svc', (b) => b.withDefaultHeader('X-Extra', '1'));
      final c2 = factory.createClient('svc');

      expect(c1, isNot(same(c2)));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — clear', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;

    setUp(() => factory = HttpClientFactory());

    test('clear() removes all named registrations', () {
      factory
        ..addClient('a', (b) => b.withHttpClient(_mockClient()))
        ..addClient('b', (b) => b.withHttpClient(_mockClient()));

      factory.clear();

      expect(factory.hasClient('a'), isFalse);
      expect(factory.hasClient('b'), isFalse);
      expect(factory.registeredNames, isEmpty);
    });

    test('clear() removes all typed registrations', () {
      factory.addTypedClient<_UserService>(
        _UserService.new,
        configure: (b) => b.withHttpClient(_mockClient()),
      );
      factory.clear();

      expect(factory.registeredTypes, isEmpty);
      expect(
        () => factory.createTypedClient<_UserService>(),
        throwsA(isA<StateError>()),
      );
    });

    test('clear() removes default configurators', () async {
      final mockHttp = _CallCountingClient();
      factory.configureDefaults(
        (b) => b.withDefaultHeader('X-Should-Be-Gone', 'yes'),
      );
      factory.clear();

      factory.addClient(
        'api',
        (b) => b
            .withHttpClient(mockHttp)
            .withBaseUri(Uri.parse('https://api.example.com')),
      );
      await factory.createClient('api').get(Uri.parse('/ping'));

      expect(
        mockHttp.capturedHeaders.first.containsKey('x-should-be-gone'),
        isFalse,
      );
    });

    test('factory is reusable after clear()', () {
      factory.addClient('old', (b) => b.withHttpClient(_mockClient()));
      factory.clear();

      factory.addClient('new', (b) => b.withHttpClient(_mockClient()));
      expect(factory.createClient('new'), isA<ResilientHttpClient>());
      expect(factory.hasClient('old'), isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — introspection', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('toString() lists registered client names', () {
      final factory = HttpClientFactory()
        ..addClient('alpha', (b) => b.withHttpClient(_mockClient()))
        ..addClient('beta', (b) => b.withHttpClient(_mockClient()));

      final s = factory.toString();
      expect(s, contains('HttpClientFactory'));
      expect(s, contains('"alpha"'));
      expect(s, contains('"beta"'));
    });

    test('toString() labels empty-string name as (default)', () {
      final factory = HttpClientFactory()
        ..addClient('', (b) => b.withHttpClient(_mockClient()));

      expect(factory.toString(), contains('(default)'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientFactory — full integration', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('retry policy on named client retries transient failures', () async {
      var callCount = 0;
      final mockHttp = http_testing.MockClient((_) async {
        callCount++;
        if (callCount < 3) throw Exception('transient');
        return http.Response('ok', 200);
      });

      final factory = HttpClientFactory()
        ..addClient(
            'resilient',
            (b) => b
                .withBaseUri(Uri.parse('https://api.example.com'))
                .withPolicy(Policy.retry(maxRetries: 3))
                .withHttpClient(mockHttp),);

      final client = factory.createClient('resilient');
      final response = await client.get(Uri.parse('/data'));

      expect(response.statusCode, 200);
      expect(callCount, 3);
    });

    test('typed service client calls go through the resilience pipeline',
        () async {
      var callCount = 0;
      final mockHttp = http_testing.MockClient((_) async {
        callCount++;
        if (callCount < 2) throw Exception('transient');
        return http.Response('{"id":42}', 200);
      });

      final factory = HttpClientFactory()
        ..addTypedClient<_UserService>(
          _UserService.new,
          clientName: 'users',
          configure: (b) => b
              .withBaseUri(Uri.parse('https://users.svc'))
              .withPolicy(Policy.retry(maxRetries: 2))
              .withHttpClient(mockHttp),
        );

      final service = factory.createTypedClient<_UserService>();
      final response = await service.getUser(42);

      expect(response.statusCode, 200);
      expect(callCount, 2);
    });

    test('default header plus per-client header are both present', () async {
      final mockHttp = _CallCountingClient();

      final factory = HttpClientFactory()
        ..configureDefaults((b) => b.withDefaultHeader('X-Global', 'yes'))
        ..addClient(
            'api',
            (b) => b
                .withBaseUri(Uri.parse('https://api.example.com'))
                .withDefaultHeader('X-Service', 'api')
                .withHttpClient(mockHttp),);

      await factory.createClient('api').get(Uri.parse('/resource'));
      final headers = mockHttp.capturedHeaders.first;

      expect(headers['x-global'], 'yes');
      expect(headers['x-service'], 'api');
    });

    test('pipeline builder policy integrates correctly via withPolicy',
        () async {
      var callCount = 0;
      final mockHttp = http_testing.MockClient((_) async {
        callCount++;
        if (callCount < 3) throw Exception('flap');
        return http.Response('ok', 200);
      });

      final resiliencePolicy =
          ResiliencePipelineBuilder().addRetry(maxRetries: 3).build();

      final factory = HttpClientFactory()
        ..addClient(
            'service',
            (b) => b
                .withBaseUri(Uri.parse('https://service.example.com'))
                .withPolicy(resiliencePolicy)
                .withHttpClient(mockHttp),);

      final resp =
          await factory.createClient('service').get(Uri.parse('/test'));
      expect(resp.statusCode, 200);
      expect(callCount, 3);
    });

    test('factory instances are independent — separate registries', () {
      final f1 = HttpClientFactory()
        ..addClient('svc', (b) => b.withHttpClient(_mockClient()));
      final f2 = HttpClientFactory();

      expect(f1.hasClient('svc'), isTrue);
      expect(f2.hasClient('svc'), isFalse);
    });

    test('multiple verb methods use the same underlying pipeline', () async {
      final mockHttp = _CallCountingClient();

      final factory = HttpClientFactory()
        ..addClient(
            'api',
            (b) => b
                .withBaseUri(Uri.parse('https://api.example.com'))
                .withHttpClient(mockHttp),);

      final client = factory.createClient('api');
      await client.get(Uri.parse('/resource'));
      await client.post(Uri.parse('/resource'), body: '{}');
      await client.put(Uri.parse('/resource'), body: '{}');
      await client.patch(Uri.parse('/resource'), body: '{}');
      await client.delete(Uri.parse('/resource'));

      expect(mockHttp.callCount, 5);
    });
  });
}
