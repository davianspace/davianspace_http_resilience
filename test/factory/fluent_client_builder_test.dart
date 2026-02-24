import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Returns a mock client that always responds with [statusCode] / [body].
http.Client _mockClient({int statusCode = 200, String body = 'OK'}) =>
    http_testing.MockClient(
      (_) async => http.Response(body, statusCode),
    );

/// Returns a mock client that throws [error] on every call.
http.Client _throwingClient(Object error) =>
    http_testing.MockClient((_) => Future.error(error));

/// A counter-based mock client: succeeds after [failCount] failures.
final class _FlakyClient extends http.BaseClient {
  _FlakyClient({
    required this.failCount,
    this.failStatusCode = 503,
  });

  final int failCount;
  final int failStatusCode;
  int _calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _calls++;
    final code = _calls <= failCount ? failStatusCode : 200;
    return http.StreamedResponse(
      Stream.value('call $_calls'.codeUnits),
      code,
      request: request,
    );
  }

  int get calls => _calls;
}

/// An exception that signals a permanent (non-retryable) failure.
final class _PermanentException implements Exception {
  const _PermanentException();
  @override
  String toString() => '_PermanentException';
}

/// A subclass of [http.BaseClient] that captures all request headers with
/// lowercase keys.
///
/// Used by tests that need to verify default-header propagation, because
/// [`BaseClient.send`] receives the finalized [http.BaseRequest] with all
/// headers intact.
final class _HeaderCapturingClient extends http.BaseClient {
  final captured = <String, String>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    for (final e in request.headers.entries) {
      captured[e.key.toLowerCase()] = e.value;
    }
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
  // ── Construction & defaults ────────────────────────────────────────────────
  group('FluentHttpClientBuilder construction', () {
    test('no-arg constructor sets empty name and zero steps', () {
      final b = FluentHttpClientBuilder();
      expect(b.name, isEmpty);
      expect(b.stepCount, 0);
      expect(b.isBound, isFalse);
    });

    test('named constructor sets name', () {
      final b = FluentHttpClientBuilder('catalog');
      expect(b.name, 'catalog');
    });

    test('build() on empty builder returns a ResilientHttpClient', () {
      final client =
          FluentHttpClientBuilder().withHttpClient(_mockClient()).build();
      expect(client, isA<ResilientHttpClient>());
    });

    test('toString contains name, stepCount, and bound flag', () {
      final s = FluentHttpClientBuilder('api').toString();
      expect(s, contains('"api"'));
      expect(s, contains('0 step(s)'));
      expect(s, contains('bound=false'));
    });

    test('toString uses "unnamed" for empty name', () {
      final s = FluentHttpClientBuilder().toString();
      expect(s, contains('unnamed'));
    });
  });

  // ── Immutability ───────────────────────────────────────────────────────────
  group('Immutability', () {
    test('withBaseUri returns a new instance; original is unchanged', () {
      final base = FluentHttpClientBuilder('a');
      final withUri = base.withBaseUri(Uri.parse('https://example.com'));

      expect(withUri, isNot(same(base)));
      // Build original — if it had a baseUri it would resolve relative paths.
      // We only verify the original still has no steps and same name.
      expect(base.stepCount, 0);
      expect(withUri.name, 'a');
    });

    test('withDefaultHeader returns a new instance; original unchanged', () {
      final base = FluentHttpClientBuilder();
      final next = base.withDefaultHeader('X-Foo', 'bar');
      expect(next, isNot(same(base)));
      // Original still builds fine without the header.
      expect(base.stepCount, 0);
      expect(next.stepCount, 0); // headers are not pipeline steps
    });

    test('addRetryPolicy returns a new instance with one extra step', () {
      final base = FluentHttpClientBuilder();
      final next = base.addRetryPolicy(maxRetries: 3);
      expect(next, isNot(same(base)));
      expect(base.stepCount, 0);
      expect(next.stepCount, 1);
    });

    test('forking two branches from a common base is independent', () {
      final base =
          FluentHttpClientBuilder().addTimeout(const Duration(seconds: 5));

      final branchA = base.addRetryPolicy(maxRetries: 3);
      final branchB = base
          .addCircuitBreakerPolicy(circuitName: 'svc-b')
          .addBulkheadPolicy(maxConcurrency: 10);

      expect(base.stepCount, 1);
      expect(branchA.stepCount, 2);
      expect(branchB.stepCount, 3);

      // Branches don't see each other's steps.
      // Building branchA then branchB should both succeed.
      final clientA = branchA.withHttpClient(_mockClient()).build();
      final clientB = branchB.withHttpClient(_mockClient()).build();
      expect(clientA, isA<ResilientHttpClient>());
      expect(clientB, isA<ResilientHttpClient>());
    });

    test('withHttpClient returns new instance; original unaffected', () {
      final base = FluentHttpClientBuilder();
      final withClient = base.withHttpClient(_mockClient());
      expect(withClient, isNot(same(base)));
      expect(base.stepCount, 0);
    });
  });

  // ── Base URI ───────────────────────────────────────────────────────────────
  group('withBaseUri', () {
    test('resolves relative URI segments against base path', () async {
      Uri? captured;
      final mockHttp = http_testing.MockClient((req) async {
        captured = req.url;
        return http.Response('ok', 200);
      });

      final client = FluentHttpClientBuilder()
          .withBaseUri(Uri.parse('https://api.example.com/v2/'))
          .withHttpClient(mockHttp)
          .build();

      // Relative path (no leading /) is joined under the base path.
      await client.get(Uri.parse('users/1'));
      expect(captured?.host, 'api.example.com');
      expect(captured?.path, '/v2/users/1');
    });
  });

  // ── Default headers ────────────────────────────────────────────────────────
  group('withDefaultHeader', () {
    test('merges default headers into every request', () async {
      final capturingClient = _HeaderCapturingClient();

      await FluentHttpClientBuilder()
          .withDefaultHeader('X-Client', 'fluent-dsl')
          .withDefaultHeader('Accept', 'application/json')
          .withHttpClient(capturingClient)
          .build()
          .get(Uri.parse('https://example.com'));

      expect(capturingClient.captured['x-client'], 'fluent-dsl');
      expect(capturingClient.captured['accept'], 'application/json');
    });

    test('later header overwrites earlier one for same name', () async {
      final capturingClient = _HeaderCapturingClient();

      await FluentHttpClientBuilder()
          .withDefaultHeader('X-Version', 'v1')
          .withDefaultHeader('X-Version', 'v2')
          .withHttpClient(capturingClient)
          .build()
          .get(Uri.parse('https://example.com'));

      expect(capturingClient.captured['x-version'], 'v2');
    });
  });

  // ── addRetryPolicy ─────────────────────────────────────────────────────────
  group('addRetryPolicy', () {
    test('retries transient exceptions up to maxRetries', () async {
      var calls = 0;
      final client = FluentHttpClientBuilder()
          .addRetryPolicy(maxRetries: 2)
          .withHttpClient(
        http_testing.MockClient((_) async {
          calls++;
          if (calls < 3) throw Exception('transient');
          return http.Response('OK', 200);
        }),
      ).build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(calls, 3); // 1 initial + 2 retries
    });

    test('does not retry when retryOn returns false', () async {
      var calls = 0;

      final client = FluentHttpClientBuilder()
          .addRetryPolicy(
        maxRetries: 3,
        retryOn: (ex, _) => ex is! _PermanentException,
      )
          .withHttpClient(
        http_testing.MockClient((_) async {
          calls++;
          throw const _PermanentException();
        }),
      ).build();

      await expectLater(
        client.get(Uri.parse('https://example.com')),
        throwsA(isA<_PermanentException>()),
      );
      expect(calls, 1); // no retries
    });

    test('stepCount increments by 1', () {
      final b = FluentHttpClientBuilder().addRetryPolicy(maxRetries: 2);
      expect(b.stepCount, 1);
    });
  });

  // ── addHttpRetryPolicy ─────────────────────────────────────────────────────
  group('addHttpRetryPolicy', () {
    test('retries on configured status codes', () async {
      final flaky = _FlakyClient(failCount: 2);

      final client = FluentHttpClientBuilder()
          .addHttpRetryPolicy(
            maxRetries: 3,
            retryOnStatusCodes: [503],
          )
          .withHttpClient(flaky)
          .build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(flaky.calls, 3);
    });

    test('does not retry non-configured status codes', () async {
      final flaky = _FlakyClient(failCount: 2, failStatusCode: 404);

      final client = FluentHttpClientBuilder()
          .addHttpRetryPolicy(
            maxRetries: 3,
            retryOnStatusCodes: [500, 503],
          )
          .withHttpClient(flaky)
          .build();

      // 404 is not in the retry list — returns after first attempt.
      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 404);
      expect(flaky.calls, 1);
    });

    test('also retries on exceptions (not only status codes)', () async {
      var calls = 0;

      final client = FluentHttpClientBuilder()
          .addHttpRetryPolicy(maxRetries: 2)
          .withHttpClient(
        http_testing.MockClient((_) async {
          calls++;
          if (calls < 3) throw Exception('network error');
          return http.Response('OK', 200);
        }),
      ).build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(calls, 3);
    });
  });

  // ── addRetryForeverPolicy ──────────────────────────────────────────────────
  group('addRetryForeverPolicy', () {
    test('retries indefinitely until success', () async {
      var calls = 0;

      final client = FluentHttpClientBuilder()
          .addRetryForeverPolicy(backoff: const NoBackoff())
          .withHttpClient(
        http_testing.MockClient((_) async {
          calls++;
          if (calls < 5) throw Exception('transient');
          return http.Response('OK', 200);
        }),
      ).build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(calls, 5);
    });

    test('stops when CancellationToken is cancelled', () async {
      final token = CancellationToken();
      var calls = 0;

      final client = FluentHttpClientBuilder()
          .addRetryForeverPolicy(
        backoff: const NoBackoff(),
        cancellationToken: token,
      )
          .withHttpClient(
        http_testing.MockClient((_) async {
          calls++;
          if (calls == 3) token.cancel('test cancel');
          throw Exception('transient');
        }),
      ).build();

      await expectLater(
        client.get(Uri.parse('https://example.com')),
        throwsA(isA<CancellationException>()),
      );
      expect(calls, greaterThanOrEqualTo(3));
    });
  });

  // ── addTimeout ─────────────────────────────────────────────────────────────
  group('addTimeout', () {
    test('throws HttpTimeoutException when action exceeds timeout', () async {
      final client = FluentHttpClientBuilder()
          .addTimeout(const Duration(milliseconds: 50))
          .withHttpClient(
        http_testing.MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('late', 200);
        }),
      ).build();

      await expectLater(
        client.get(Uri.parse('https://example.com')),
        throwsA(isA<HttpTimeoutException>()),
      );
    });

    test('completes normally when action finishes before timeout', () async {
      final client = FluentHttpClientBuilder()
          .addTimeout(const Duration(seconds: 5))
          .withHttpClient(_mockClient())
          .build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
    });
  });

  // ── addCircuitBreakerPolicy ────────────────────────────────────────────────
  group('addCircuitBreakerPolicy', () {
    test('opens after failureThreshold consecutive failures', () async {
      final registry = CircuitBreakerRegistry();

      final client = FluentHttpClientBuilder()
          .addCircuitBreakerPolicy(
            circuitName: 'test-cb',
            failureThreshold: 3,
            registry: registry,
          )
          .withHttpClient(_throwingClient(Exception('down')))
          .build();

      // First 3 failures: circuit trips on the 3rd.
      for (var i = 0; i < 3; i++) {
        try {
          await client.get(Uri.parse('https://example.com'));
        } on Exception catch (_) {}
      }

      // Next call should throw CircuitOpenException immediately.
      await expectLater(
        client.get(Uri.parse('https://example.com')),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    test('stepCount increments by 1', () {
      final b =
          FluentHttpClientBuilder().addCircuitBreakerPolicy(circuitName: 'svc');
      expect(b.stepCount, 1);
    });
  });

  // ── addFallbackPolicy ──────────────────────────────────────────────────────
  group('addFallbackPolicy', () {
    test('returns fallback value on exception', () async {
      final client = FluentHttpClientBuilder()
          .addFallbackPolicy(
            fallbackAction: (_, __) async =>
                HttpResponse(statusCode: 200, body: 'fallback'.codeUnits),
          )
          .withHttpClient(_throwingClient(Exception('boom')))
          .build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(response.bodyAsString, 'fallback');
    });

    test('does not trigger fallback on success', () async {
      final client = FluentHttpClientBuilder()
          .addFallbackPolicy(
            fallbackAction: (_, __) async =>
                HttpResponse(statusCode: 503, body: 'fallback'.codeUnits),
          )
          .withHttpClient(_mockClient(body: 'real'))
          .build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(response.bodyAsString, 'real');
    });

    test('onFallback callback is invoked', () async {
      Object? capturedEx;

      final client = FluentHttpClientBuilder()
          .addFallbackPolicy(
            fallbackAction: (_, __) async =>
                HttpResponse(statusCode: 200, body: []),
            onFallback: (ex, _) => capturedEx = ex,
          )
          .withHttpClient(_throwingClient(Exception('trigger')))
          .build();

      await client.get(Uri.parse('https://example.com'));
      expect(capturedEx, isA<Exception>());
    });
  });

  // ── addBulkheadPolicy ──────────────────────────────────────────────────────
  group('addBulkheadPolicy', () {
    test('rejects excess requests when queue is full', () async {
      final completer = Completer<void>();
      var rejections = 0;

      final client = FluentHttpClientBuilder()
          .addBulkheadPolicy(
        maxConcurrency: 1,
        maxQueueDepth: 0, // no queuing — reject immediately
        queueTimeout: const Duration(milliseconds: 50),
      )
          .withHttpClient(
        http_testing.MockClient((_) async {
          await completer.future; // block until released
          return http.Response('ok', 200);
        }),
      ).build();

      // Launch one request that will block.
      final req1 = client.get(Uri.parse('https://example.com'));

      // Give the first request time to acquire the semaphore.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Second request should be rejected.
      try {
        await client.get(Uri.parse('https://example.com'));
      } on BulkheadRejectedException {
        rejections++;
      }

      completer.complete();
      await req1;

      expect(rejections, 1);
    });
  });

  // ── addBulkheadIsolationPolicy ─────────────────────────────────────────────
  group('addBulkheadIsolationPolicy', () {
    test('allows requests up to maxConcurrentRequests', () async {
      final client = FluentHttpClientBuilder()
          .addBulkheadIsolationPolicy(maxConcurrentRequests: 5)
          .withHttpClient(_mockClient())
          .build();

      final responses = await Future.wait([
        client.get(Uri.parse('https://example.com')),
        client.get(Uri.parse('https://example.com')),
      ]);
      for (final r in responses) {
        expect(r.statusCode, 200);
      }
    });

    test('stepCount increments by 1', () {
      final b = FluentHttpClientBuilder().addBulkheadIsolationPolicy();
      expect(b.stepCount, 1);
    });
  });

  // ── withResiliencePolicy ───────────────────────────────────────────────────
  group('withResiliencePolicy', () {
    test('applies an arbitrary ResiliencePolicy', () async {
      var executions = 0;

      // A policy that just counts executions.
      final counting = _CountingPolicy(onExecute: () => executions++);

      final client = FluentHttpClientBuilder()
          .withResiliencePolicy(counting)
          .withHttpClient(_mockClient())
          .build();

      await client.get(Uri.parse('https://example.com'));
      expect(executions, 1);
    });

    test('stepCount increments by 1', () {
      final b = FluentHttpClientBuilder()
          .withResiliencePolicy(NoOpResiliencePolicy());
      expect(b.stepCount, 1);
    });
  });

  // ── withHandler ────────────────────────────────────────────────────────────
  group('withHandler', () {
    test('raw DelegatingHandler is inserted into pipeline', () async {
      var intercepted = false;

      final client = FluentHttpClientBuilder()
          .withHandler(_InterceptingHandler(onSend: () => intercepted = true))
          .withHttpClient(_mockClient())
          .build();

      await client.get(Uri.parse('https://example.com'));
      expect(intercepted, isTrue);
    });
  });

  // ── applyTo ────────────────────────────────────────────────────────────────
  group('applyTo', () {
    test('merges DSL steps into an existing HttpClientBuilder', () async {
      var calls = 0;
      final dsl = FluentHttpClientBuilder().addRetryPolicy(maxRetries: 2);

      final raw = HttpClientBuilder()
        ..withHttpClient(
          http_testing.MockClient((_) async {
            calls++;
            if (calls < 3) throw Exception('transient');
            return http.Response('OK', 200);
          }),
        );

      dsl.applyTo(raw);
      final client = raw.build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(calls, 3);
    });
  });

  // ── Policy composition order ───────────────────────────────────────────────
  group('Policy composition order', () {
    test('fallback catches RetryExhaustedException from inner retry', () async {
      var calls = 0;
      var fallbackFired = false;

      final client = FluentHttpClientBuilder()
          .addFallbackPolicy(
            fallbackAction: (_, __) async {
              fallbackFired = true;
              return HttpResponse(statusCode: 200, body: 'fallback'.codeUnits);
            },
          )
          .addRetryPolicy(maxRetries: 2)
          .withHttpClient(
            http_testing.MockClient((_) async {
              calls++;
              throw Exception('always fails');
            }),
          )
          .build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.bodyAsString, 'fallback');
      expect(fallbackFired, isTrue);
      expect(calls, 3); // 1 initial + 2 retries
    });

    test('multiple policies stack correctly: retry + timeout', () async {
      var calls = 0;

      final client = FluentHttpClientBuilder()
          .addRetryPolicy(maxRetries: 2)
          .addTimeout(const Duration(seconds: 5))
          .withHttpClient(
        http_testing.MockClient((_) async {
          calls++;
          if (calls < 3) throw Exception('transient');
          return http.Response('OK', 200);
        }),
      ).build();

      final response = await client.get(Uri.parse('https://example.com'));
      expect(response.statusCode, 200);
      expect(calls, 3);
    });
  });

  // ── Factory integration (HttpClientFactoryFluentExtension) ────────────────
  group('HttpClientFactory.forClient (factory integration)', () {
    late HttpClientFactory factory;

    setUp(() => factory = HttpClientFactory());

    test('forClient returns an unbound-by-default isBound=true builder', () {
      final b = factory.forClient('api');
      expect(b.isBound, isTrue);
      expect(b.name, 'api');
    });

    test('done() registers client lazily with the factory', () {
      factory.forClient('catalog').withHttpClient(_mockClient()).done();

      expect(factory.hasClient('catalog'), isTrue);
    });

    test('done() returns the factory for further chaining', () {
      final returned =
          factory.forClient('a').withHttpClient(_mockClient()).done();

      expect(returned, same(factory));
    });

    test('client is built lazily — not before createClient is called', () {
      // Register but don't call createClient; factory should not have built it.
      factory.forClient('lazy').withHttpClient(_mockClient()).done();

      expect(factory.hasClient('lazy'), isTrue);
      // createClient triggers the build.
      final client = factory.createClient('lazy');
      expect(client, isA<ResilientHttpClient>());
    });

    test('createClient returns a working client for the registered name',
        () async {
      factory
          .forClient('svc')
          .withBaseUri(Uri.parse('https://svc.internal'))
          .addRetryPolicy(maxRetries: 1)
          .withHttpClient(_mockClient(statusCode: 204))
          .done();

      final client = factory.createClient('svc');
      final response = await client.get(Uri.parse('/health'));
      expect(response.statusCode, 204);
    });

    test('multiple forClient registrations are independent', () async {
      factory
          .forClient('a')
          .withHttpClient(_mockClient(statusCode: 201))
          .done()
          .forClient('b')
          .withHttpClient(_mockClient(statusCode: 202))
          .done();

      final r1 =
          await factory.createClient('a').get(Uri.parse('https://e.com'));
      final r2 =
          await factory.createClient('b').get(Uri.parse('https://e.com'));
      expect(r1.statusCode, 201);
      expect(r2.statusCode, 202);
    });

    test('done() on standalone builder throws StateError', () {
      final standalone = FluentHttpClientBuilder('orphan');
      expect(standalone.done, throwsStateError);
    });

    test('factory caches the client — same instance returned on repeated calls',
        () {
      factory.forClient('cached').withHttpClient(_mockClient()).done();

      final c1 = factory.createClient('cached');
      final c2 = factory.createClient('cached');
      expect(c1, same(c2));
    });

    test('cascade style: factory..forClient().done()..forClient().done()',
        () async {
      factory
        ..forClient('x').withHttpClient(_mockClient(statusCode: 211)).done()
        ..forClient('y').withHttpClient(_mockClient(statusCode: 212)).done();

      final rx =
          await factory.createClient('x').get(Uri.parse('https://e.com'));
      final ry =
          await factory.createClient('y').get(Uri.parse('https://e.com'));
      expect(rx.statusCode, 211);
      expect(ry.statusCode, 212);
    });
  });

  // ── stepCount / inspection ─────────────────────────────────────────────────
  group('Inspection', () {
    test('stepCount tracks each add* call independently', () {
      final b = FluentHttpClientBuilder()
          .addRetryPolicy(maxRetries: 1)
          .addTimeout(const Duration(seconds: 5))
          .addCircuitBreakerPolicy(circuitName: 'svc')
          .addFallbackPolicy(
            fallbackAction: (_, __) async =>
                HttpResponse(statusCode: 200, body: []),
          );
      expect(b.stepCount, 4);
    });

    test('isBound is false for standalone builders', () {
      expect(FluentHttpClientBuilder().isBound, isFalse);
      expect(FluentHttpClientBuilder('api').isBound, isFalse);
    });

    test('isBound is true for factory-bound builders', () {
      final factory = HttpClientFactory();
      expect(factory.forClient('api').isBound, isTrue);
    });

    test('name is preserved through the mutation chain', () {
      final b = FluentHttpClientBuilder('my-svc')
          .addRetryPolicy(maxRetries: 1)
          .addTimeout(const Duration(seconds: 5));
      expect(b.name, 'my-svc');
    });
  });

  // ── base DSL matches the user's example pattern ────────────────────────────
  group('Example pattern from requirements', () {
    test('factory.forClient("api").addXxx().done() pattern works', () async {
      final factory = HttpClientFactory()
        ..forClient('api')
            .addRetryPolicy(maxRetries: 3)
            .addTimeout(const Duration(seconds: 10))
            .addFallbackPolicy(
              fallbackAction: (_, __) async =>
                  HttpResponse(statusCode: 200, body: 'cached'.codeUnits),
            )
            .addBulkheadPolicy(maxConcurrency: 20)
            .withHttpClient(_mockClient())
            .done();

      final client = factory.createClient('api');
      final response = await client.get(Uri.parse('https://api.example.com'));
      expect(response.statusCode, 200);
    });
  });
}

// ════════════════════════════════════════════════════════════════════════════
//  Internal test helpers (not part of public API)
// ════════════════════════════════════════════════════════════════════════════

/// A [ResiliencePolicy] that exposes a callback for tracking executions.
final class _CountingPolicy extends ResiliencePolicy {
  _CountingPolicy({required this.onExecute});
  final void Function() onExecute;

  @override
  Future<T> execute<T>(Future<T> Function() action) {
    onExecute();
    return action();
  }
}

/// A no-op [ResiliencePolicy] for testing escape hatches.
final class NoOpResiliencePolicy extends ResiliencePolicy {
  @override
  Future<T> execute<T>(Future<T> Function() action) => action();
}

/// A transparent [DelegatingHandler] that fires a callback on each [send].
final class _InterceptingHandler extends DelegatingHandler {
  _InterceptingHandler({required this.onSend});
  final void Function() onSend;

  @override
  Future<HttpResponse> send(HttpContext context) {
    onSend();
    return innerHandler.send(context);
  }
}
