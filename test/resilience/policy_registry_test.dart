import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test helpers
// ════════════════════════════════════════════════════════════════════════════

/// Counts [execute] invocations without affecting the action.
final class _CountingPolicy extends ResiliencePolicy {
  int executions = 0;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    executions++;
    return action();
  }

  @override
  String toString() => '_CountingPolicy';
}

/// Second distinct subtype to test type-safety.
final class _AnotherPolicy extends ResiliencePolicy {
  @override
  Future<T> execute<T>(Future<T> Function() action) => action();

  @override
  String toString() => '_AnotherPolicy';
}

/// A [http.BaseClient] that tracks calls and recorded headers.
final class _TrackingClient extends http.BaseClient {
  int callCount = 0;
  final List<Map<String, String>> capturedHeaders = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    callCount++;
    capturedHeaders.add({
      for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
    });
    return http.StreamedResponse(
      Stream.value('ok'.codeUnits),
      200,
      request: request,
    );
  }
}

/// MockClient that throws [failTimes] times then succeeds.
http.Client _flakyClient(int failTimes) {
  var calls = 0;
  return http_testing.MockClient((_) async {
    calls++;
    if (calls <= failTimes) throw Exception('transient $calls');
    return http.Response('ok', 200);
  });
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — registration', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('add() registers a policy successfully', () {
      final registry = PolicyRegistry();
      final policy = _CountingPolicy();
      registry.add('test', policy);
      expect(registry.contains('test'), isTrue);
    });

    test('add() returns the registry for fluent chaining', () {
      final registry = PolicyRegistry();
      final returned = registry.add('a', _CountingPolicy());
      expect(returned, same(registry));
    });

    test('add() throws StateError when name is already registered', () {
      final registry = PolicyRegistry()..add('existing', _CountingPolicy());
      expect(
        () => registry.add('existing', _CountingPolicy()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('existing'),
          ),
        ),
      );
    });

    test('addOrReplace() registers a new policy', () {
      final registry = PolicyRegistry();
      registry.addOrReplace('new', _CountingPolicy());
      expect(registry.contains('new'), isTrue);
    });

    test('addOrReplace() overwrites an existing policy', () {
      final registry = PolicyRegistry()..add('key', _CountingPolicy());
      final replacement = _AnotherPolicy();
      registry.addOrReplace('key', replacement);
      expect(registry.get('key'), same(replacement));
    });

    test('addOrReplace() returns the registry for fluent chaining', () {
      final registry = PolicyRegistry();
      final returned = registry.addOrReplace('a', _CountingPolicy());
      expect(returned, same(registry));
    });

    test('replace() updates an existing policy', () {
      final original = _CountingPolicy();
      final updated = _CountingPolicy();
      final registry = PolicyRegistry()..add('key', original);

      registry.replace('key', updated);
      expect(registry.get('key'), same(updated));
    });

    test('replace() returns the registry for fluent chaining', () {
      final registry = PolicyRegistry()..add('k', _CountingPolicy());
      final returned = registry.replace('k', _CountingPolicy());
      expect(returned, same(registry));
    });

    test('replace() throws StateError for an unregistered name', () {
      final registry = PolicyRegistry();
      expect(
        () => registry.replace('missing', _CountingPolicy()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing'),
          ),
        ),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — retrieval', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('get<T>() returns the registered policy typed correctly', () {
      final policy = _CountingPolicy();
      final registry = PolicyRegistry()..add('counter', policy);
      final result = registry.get<_CountingPolicy>('counter');
      expect(result, same(policy));
    });

    test('get() without type argument returns the base ResiliencePolicy', () {
      final policy = _CountingPolicy();
      final registry = PolicyRegistry()..add('p', policy);
      expect(registry.get('p'), same(policy));
    });

    test('get<T>() throws StateError for an unregistered name', () {
      final registry = PolicyRegistry();
      expect(
        () => registry.get<_CountingPolicy>('unknown'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unknown'),
          ),
        ),
      );
    });

    test('get<T>() throws StateError when the policy is a different subtype',
        () {
      final registry = PolicyRegistry()..add('p', _CountingPolicy());
      expect(
        () => registry.get<_AnotherPolicy>('p'),
        throwsA(isA<StateError>()),
      );
    });

    test('tryGet<T>() returns the policy when name and type match', () {
      final policy = _CountingPolicy();
      final registry = PolicyRegistry()..add('c', policy);
      expect(registry.tryGet<_CountingPolicy>('c'), same(policy));
    });

    test('tryGet<T>() returns null for an unregistered name', () {
      final registry = PolicyRegistry();
      expect(registry.tryGet<_CountingPolicy>('missing'), isNull);
    });

    test('tryGet<T>() returns null when the policy is a different subtype', () {
      final registry = PolicyRegistry()..add('p', _CountingPolicy());
      expect(registry.tryGet<_AnotherPolicy>('p'), isNull);
    });

    test('tryGet<T>() does NOT throw for any input', () {
      final registry = PolicyRegistry()..add('p', _CountingPolicy());
      // Missing name — no throw
      expect(registry.tryGet('gone'), isNull);
      // Wrong type — no throw
      expect(registry.tryGet<_AnotherPolicy>('p'), isNull);
    });

    test('multiple policies are all independently retrievable', () {
      final p1 = _CountingPolicy();
      final p2 = _AnotherPolicy();
      final p3 = Policy.retry(maxRetries: 3);

      final registry = PolicyRegistry()
        ..add('c', p1)
        ..add('a', p2)
        ..add('r', p3);

      expect(registry.get<_CountingPolicy>('c'), same(p1));
      expect(registry.get<_AnotherPolicy>('a'), same(p2));
      expect(registry.get<RetryResiliencePolicy>('r'), same(p3));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — removal', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('remove() returns and deletes an existing policy', () {
      final policy = _CountingPolicy();
      final registry = PolicyRegistry()..add('p', policy);
      final removed = registry.remove('p');
      expect(removed, same(policy));
      expect(registry.contains('p'), isFalse);
    });

    test('remove() returns null for a non-existent name', () {
      final registry = PolicyRegistry();
      expect(registry.remove('nope'), isNull);
    });

    test('after remove() the name can be re-registered with add()', () {
      final registry = PolicyRegistry()..add('p', _CountingPolicy());
      registry.remove('p');
      expect(() => registry.add('p', _CountingPolicy()), returnsNormally);
    });

    test('clear() empties the registry', () {
      final registry = PolicyRegistry()
        ..add('a', _CountingPolicy())
        ..add('b', _AnotherPolicy());

      registry.clear();
      expect(registry.isEmpty, isTrue);
      expect(registry.length, 0);
    });

    test('clear() returns the registry for fluent chaining', () {
      final registry = PolicyRegistry()..add('x', _CountingPolicy());
      expect(registry.clear(), same(registry));
    });

    test('registry is fully reusable after clear()', () {
      final registry = PolicyRegistry()..add('old', _CountingPolicy());
      registry.clear();
      registry.add('new', _AnotherPolicy());
      expect(registry.contains('old'), isFalse);
      expect(registry.contains('new'), isTrue);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — introspection', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('contains() returns true for registered name, false otherwise', () {
      final registry = PolicyRegistry()..add('present', _CountingPolicy());
      expect(registry.contains('present'), isTrue);
      expect(registry.contains('absent'), isFalse);
    });

    test('length tracks the number of registered policies', () {
      final registry = PolicyRegistry();
      expect(registry.length, 0);
      registry.add('a', _CountingPolicy());
      expect(registry.length, 1);
      registry.add('b', _AnotherPolicy());
      expect(registry.length, 2);
      registry.remove('a');
      expect(registry.length, 1);
    });

    test('isEmpty and isNotEmpty are correct', () {
      final registry = PolicyRegistry();
      expect(registry.isEmpty, isTrue);
      expect(registry.isNotEmpty, isFalse);
      registry.add('x', _CountingPolicy());
      expect(registry.isEmpty, isFalse);
      expect(registry.isNotEmpty, isTrue);
    });

    test('keys returns all registered names', () {
      final registry = PolicyRegistry()
        ..add('alpha', _CountingPolicy())
        ..add('beta', _AnotherPolicy());
      expect(registry.keys, containsAll(['alpha', 'beta']));
    });

    test('keys is unmodifiable', () {
      final registry = PolicyRegistry()..add('x', _CountingPolicy());
      expect(
        () => registry.keys.add('y'),
        throwsUnsupportedError,
      );
    });

    test('toMap() returns an unmodifiable snapshot of all entries', () {
      final p1 = _CountingPolicy();
      final p2 = _AnotherPolicy();
      final registry = PolicyRegistry()
        ..add('a', p1)
        ..add('b', p2);

      final map = registry.toMap();
      expect(map['a'], same(p1));
      expect(map['b'], same(p2));
      expect(map.length, 2);
    });

    test('toMap() snapshot is unmodifiable', () {
      final registry = PolicyRegistry()..add('x', _CountingPolicy());
      expect(
        () => registry.toMap().remove('x'),
        throwsUnsupportedError,
      );
    });

    test('toMap() is a snapshot — later mutations do not affect it', () {
      final registry = PolicyRegistry()..add('a', _CountingPolicy());
      final snapshot = registry.toMap();
      registry.add('b', _AnotherPolicy());
      expect(snapshot.length, 1); // still 1 from when snapshot was taken
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — singleton', () {
    // ──────────────────────────────────────────────────────────────────────────

    // Always reset the singleton before and after each test.
    setUp(PolicyRegistry.resetInstance);
    tearDown(PolicyRegistry.resetInstance);

    test('PolicyRegistry.instance is lazily created on first access', () {
      // Simply accessing it should not throw.
      final inst = PolicyRegistry.instance;
      expect(inst, isA<PolicyRegistry>());
    });

    test('repeated access returns the same instance', () {
      final i1 = PolicyRegistry.instance;
      final i2 = PolicyRegistry.instance;
      expect(i1, same(i2));
    });

    test('resetInstance() discards the old instance', () {
      final old = PolicyRegistry.instance;
      PolicyRegistry.resetInstance();
      final fresh = PolicyRegistry.instance;
      expect(fresh, isNot(same(old)));
    });

    test('resetInstance clears policies registered in the old instance', () {
      PolicyRegistry.instance.add('temp', _CountingPolicy());
      PolicyRegistry.resetInstance();
      expect(PolicyRegistry.instance.contains('temp'), isFalse);
    });

    test('instance is independent from explicitly constructed registries', () {
      final explicit = PolicyRegistry()..add('p', _CountingPolicy());
      expect(PolicyRegistry.instance.contains('p'), isFalse);
      // Modifying the singleton does not affect the explicit registry.
      PolicyRegistry.instance.add('q', _AnotherPolicy());
      expect(explicit.contains('q'), isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — toString', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('toString() for empty registry says "empty"', () {
      expect(PolicyRegistry().toString(), contains('empty'));
    });

    test('toString() lists policy count and names', () {
      final registry = PolicyRegistry()
        ..add('retry', Policy.retry(maxRetries: 1))
        ..add('timeout', Policy.timeout(const Duration(seconds: 5)));

      final s = registry.toString();
      expect(s, contains('PolicyRegistry(2 policies)'));
      expect(s, contains('"retry"'));
      expect(s, contains('"timeout"'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — integration with HttpClientBuilder', () {
    // ──────────────────────────────────────────────────────────────────────────

    test(
        'withPolicyFromRegistry resolves from an explicit registry and adds a '
        'PolicyHandler', () async {
      final counting = _CountingPolicy();
      final registry = PolicyRegistry()..add('my-policy', counting);
      final tracking = _TrackingClient();

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withPolicyFromRegistry('my-policy', registry: registry)
          .withHttpClient(tracking)
          .build();

      await client.get(Uri.parse('/ping'));
      expect(counting.executions, 1);
    });

    test(
        'withPolicyFromRegistry resolves from the global instance when registry '
        'is omitted', () async {
      PolicyRegistry.resetInstance();
      final counting = _CountingPolicy();
      PolicyRegistry.instance.add('global-policy', counting);
      final tracking = _TrackingClient();

      try {
        final client = HttpClientBuilder()
            .withBaseUri(Uri.parse('https://example.com'))
            .withPolicyFromRegistry('global-policy')
            .withHttpClient(tracking)
            .build();

        await client.get(Uri.parse('/ping'));
        expect(counting.executions, 1);
      } finally {
        PolicyRegistry.resetInstance();
      }
    });

    test('withPolicyFromRegistry throws StateError for unknown name', () {
      final registry = PolicyRegistry();
      expect(
        () => HttpClientBuilder().withPolicyFromRegistry(
          'does-not-exist',
          registry: registry,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
        'multiple withPolicyFromRegistry calls each add an independent handler',
        () async {
      final p1 = _CountingPolicy();
      final p2 = _CountingPolicy();
      final registry = PolicyRegistry()
        ..add('pol-1', p1)
        ..add('pol-2', p2);

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withPolicyFromRegistry('pol-1', registry: registry)
          .withPolicyFromRegistry('pol-2', registry: registry)
          .withHttpClient(_TrackingClient())
          .build();

      await client.get(Uri.parse('/resource'));
      expect(p1.executions, 1);
      expect(p2.executions, 1);
    });

    test('withPolicyFromRegistry with a retry policy actually retries',
        () async {
      final registry = PolicyRegistry()
        ..add('retry3', Policy.retry(maxRetries: 3));

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withPolicyFromRegistry('retry3', registry: registry)
          .withHttpClient(_flakyClient(2))
          .build();

      final resp = await client.get(Uri.parse('/data'));
      expect(resp.statusCode, 200);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — integration with ResiliencePipelineBuilder', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('addPolicyFromRegistry appends the resolved policy to the pipeline',
        () {
      final timeout = Policy.timeout(const Duration(seconds: 5));
      final retry = Policy.retry(maxRetries: 2);
      final registry = PolicyRegistry()
        ..add('timeout', timeout)
        ..add('retry', retry);

      final wrap = ResiliencePipelineBuilder()
          .addPolicyFromRegistry('timeout', registry: registry)
          .addPolicyFromRegistry('retry', registry: registry)
          .build() as PolicyWrap;

      expect(wrap.policies, hasLength(2));
      expect(wrap.policies[0], same(timeout));
      expect(wrap.policies[1], same(retry));
    });

    test('addPolicyFromRegistry can mix with addPolicy and other add* methods',
        () {
      final timeout = Policy.timeout(const Duration(seconds: 10));
      final registry = PolicyRegistry()..add('timeout', timeout);

      final wrap = ResiliencePipelineBuilder()
          .addPolicyFromRegistry('timeout', registry: registry)
          .addRetry(maxRetries: 3)
          .build() as PolicyWrap;

      expect(wrap.policies[0], same(timeout));
      expect(wrap.policies[1], isA<RetryResiliencePolicy>());
    });

    test('addPolicyFromRegistry resolves from global instance when omitted',
        () {
      PolicyRegistry.resetInstance();
      final retry = Policy.retry(maxRetries: 1);
      PolicyRegistry.instance.add('r', retry);

      try {
        final built = ResiliencePipelineBuilder()
            .addPolicyFromRegistry('r')
            .addTimeout(const Duration(seconds: 5))
            .build() as PolicyWrap;

        expect(built.policies[0], same(retry));
      } finally {
        PolicyRegistry.resetInstance();
      }
    });

    test('addPolicyFromRegistry throws StateError for unknown name', () {
      final registry = PolicyRegistry();
      expect(
        () => ResiliencePipelineBuilder()
            .addPolicyFromRegistry('not-there', registry: registry),
        throwsA(isA<StateError>()),
      );
    });

    test('pipeline built from registry policies executes with correct order',
        () async {
      final log = <String>[];

      // Use counting policies as named entries.
      final outer = _CountingPolicy();
      final inner = _CountingPolicy();
      final registry = PolicyRegistry()
        ..add('outer', outer)
        ..add('inner', inner);

      final policy = ResiliencePipelineBuilder()
          .addPolicyFromRegistry('outer', registry: registry)
          .addPolicyFromRegistry('inner', registry: registry)
          .build();

      await policy.execute(() async {
        log.add('action');
        return 'done';
      });

      expect(log, ['action']);
      expect(outer.executions, 1);
      expect(inner.executions, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — integration with HttpClientFactory', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;
    late PolicyRegistry registry;

    setUp(() {
      factory = HttpClientFactory();
      registry = PolicyRegistry();
    });
    tearDown(() => factory.clear());

    test('policies from registry are applied to a named client', () async {
      final counting = _CountingPolicy();
      registry.add('counter', counting);

      final tracking = _TrackingClient();
      factory.addClient(
        'api',
        (b) => b
            .withBaseUri(Uri.parse('https://api.example.com'))
            .withPolicyFromRegistry('counter', registry: registry)
            .withHttpClient(tracking),
      );

      await factory.createClient('api').get(Uri.parse('/resource'));
      expect(counting.executions, 1);
    });

    test('registry policies survive factory cache invalidation and rebuild',
        () async {
      final counting = _CountingPolicy();
      registry.add('c', counting);
      final tracking = _TrackingClient();

      factory.addClient(
        'svc',
        (b) => b
            .withBaseUri(Uri.parse('https://svc.example.com'))
            .withPolicyFromRegistry('c', registry: registry)
            .withHttpClient(tracking),
      );

      await factory.createClient('svc').get(Uri.parse('/a'));
      factory.invalidate('svc'); // force rebuild
      await factory.createClient('svc').get(Uri.parse('/b'));

      // Counting policy is shared across both pipeline instances.
      expect(counting.executions, 2);
    });

    test('registry retry policy retries transient errors via factory client',
        () async {
      registry.add('retry2', Policy.retry(maxRetries: 2));

      factory.addClient(
        'flaky',
        (b) => b
            .withBaseUri(Uri.parse('https://flaky.example.com'))
            .withPolicyFromRegistry('retry2', registry: registry)
            .withHttpClient(_flakyClient(2)),
      );

      final resp = await factory.createClient('flaky').get(Uri.parse('/data'));
      expect(resp.statusCode, 200);
    });

    test('configureDefaults with registry policy applies to every client',
        () async {
      final counting = _CountingPolicy();
      registry.add('global-counter', counting);

      factory.configureDefaults(
        (b) => b.withPolicyFromRegistry('global-counter', registry: registry),
      );

      final ta = _TrackingClient();
      final tb = _TrackingClient();

      factory
        ..addClient(
          'a',
          (b) => b
              .withBaseUri(Uri.parse('https://a.example.com'))
              .withHttpClient(ta),
        )
        ..addClient(
          'b',
          (b) => b
              .withBaseUri(Uri.parse('https://b.example.com'))
              .withHttpClient(tb),
        );

      await factory.createClient('a').get(Uri.parse('/ping'));
      await factory.createClient('b').get(Uri.parse('/ping'));

      expect(counting.executions, 2);
    });

    test(
        'replacing a policy at runtime affects pipelines rebuilt after the '
        'replacement', () async {
      final first = _CountingPolicy();
      final second = _CountingPolicy();
      registry.add('policy', first);

      factory.addClient(
        'svc',
        (b) => b
            .withBaseUri(Uri.parse('https://svc.example.com'))
            .withPolicyFromRegistry('policy', registry: registry)
            .withHttpClient(_TrackingClient()),
      );

      // Build and use with the first policy.
      await factory.createClient('svc').get(Uri.parse('/a'));
      expect(first.executions, 1);
      expect(second.executions, 0);

      // Swap policy in registry, invalidate the factory cache.
      registry.replace('policy', second);
      factory.invalidate('svc');

      // Rebuild and use with the second policy.
      await factory.createClient('svc').get(Uri.parse('/b'));
      expect(first.executions, 1); // unchanged
      expect(second.executions, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PolicyRegistry — real policy types', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('RetryResiliencePolicy can be stored and retrieved typed', () {
      final registry = PolicyRegistry()
        ..add('retry', Policy.retry(maxRetries: 5));
      final retrieved = registry.get<RetryResiliencePolicy>('retry');
      expect(retrieved.maxRetries, 5);
    });

    test('TimeoutResiliencePolicy can be stored and retrieved typed', () {
      const dur = Duration(seconds: 10);
      final registry = PolicyRegistry()..add('timeout', Policy.timeout(dur));
      final retrieved = registry.get<TimeoutResiliencePolicy>('timeout');
      expect(retrieved.timeout, dur);
    });

    test('CircuitBreakerResiliencePolicy can be stored and retrieved typed',
        () {
      final registry = PolicyRegistry()
        ..add(
          'cb',
          Policy.circuitBreaker(circuitName: 'my-svc', failureThreshold: 3),
        );
      final retrieved = registry.get<CircuitBreakerResiliencePolicy>('cb');
      expect(retrieved.failureThreshold, 3);
    });

    test('BulkheadResiliencePolicy can be stored and retrieved typed', () {
      final registry = PolicyRegistry()
        ..add('bh', Policy.bulkhead(maxConcurrency: 10, maxQueueDepth: 50));
      final retrieved = registry.get<BulkheadResiliencePolicy>('bh');
      expect(retrieved.maxConcurrency, 10);
    });

    test('PolicyWrap can be stored and retrieved typed', () {
      final wrap = Policy.wrap([
        Policy.timeout(const Duration(seconds: 5)),
        Policy.retry(maxRetries: 2),
      ]);
      final registry = PolicyRegistry()..add('composite', wrap);
      final retrieved = registry.get<PolicyWrap>('composite');
      expect(retrieved.policies, hasLength(2));
    });

    test('policy executes correctly after retrieval from registry', () async {
      var callCount = 0;
      final registry = PolicyRegistry()
        ..add('retry', Policy.retry(maxRetries: 2));

      final policy = registry.get<RetryResiliencePolicy>('retry');
      await expectLater(
        policy.execute<void>(() async {
          callCount++;
          if (callCount <= 2) throw Exception('fail');
        }),
        completes,
      );
      expect(callCount, 3); // 1 initial + 2 retries
    });
  });
}
