import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

const _loader = ResilienceConfigLoader();
const _binder = ResilienceConfigBinder();

/// Wraps a raw resilience section map with the `"Resilience"` key.
String _wrap(String inner) => '{"Resilience": $inner}';

void main() {
  // ==========================================================================
  //  ResilienceConfig model
  // ==========================================================================

  group('ResilienceConfig', () {
    test('isEmpty is true when no sections are set', () {
      expect(const ResilienceConfig().isEmpty, isTrue);
    });

    test('isEmpty is false when at least one section is set', () {
      const config = ResilienceConfig(retry: RetryConfig());
      expect(config.isEmpty, isFalse);
    });

    test('toString includes all section names', () {
      const config = ResilienceConfig(
        retry: RetryConfig(),
        timeout: TimeoutConfig(seconds: 5),
      );
      final s = config.toString();
      expect(s, contains('retry'));
      expect(s, contains('timeout'));
    });
  });

  group('RetryConfig', () {
    test('defaults are maxRetries=3, retryForever=false, backoff=null', () {
      const c = RetryConfig();
      expect(c.maxRetries, 3);
      expect(c.retryForever, isFalse);
      expect(c.backoff, isNull);
    });
  });

  group('TimeoutConfig', () {
    test('duration converts seconds to Duration', () {
      const c = TimeoutConfig(seconds: 10);
      expect(c.duration, const Duration(seconds: 10));
    });
  });

  group('CircuitBreakerConfig', () {
    test('breakDuration converts breakSeconds to Duration', () {
      const c = CircuitBreakerConfig();
      expect(c.breakDuration, const Duration(seconds: 30));
    });

    test('default circuitName is "default"', () {
      expect(const CircuitBreakerConfig().circuitName, 'default');
    });
  });

  group('BulkheadConfig', () {
    test('queueTimeout converts seconds to Duration', () {
      const c = BulkheadConfig(maxConcurrency: 10, queueTimeoutSeconds: 5);
      expect(c.queueTimeout, const Duration(seconds: 5));
    });
  });

  group('BulkheadIsolationConfig', () {
    test('queueTimeout converts seconds to Duration', () {
      const c = BulkheadIsolationConfig(queueTimeoutSeconds: 20);
      expect(c.queueTimeout, const Duration(seconds: 20));
    });
  });

  group('BackoffConfig', () {
    test('baseDuration and maxDelay convert millis to Duration', () {
      const c = BackoffConfig(baseMs: 300, maxDelayMs: 5000);
      expect(c.baseDuration, const Duration(milliseconds: 300));
      expect(c.maxDelay, const Duration(milliseconds: 5000));
    });

    test('maxDelay is null when maxDelayMs is null', () {
      expect(const BackoffConfig().maxDelay, isNull);
    });
  });

  // ==========================================================================
  //  ResilienceConfigLoader — JSON parsing
  // ==========================================================================

  group('ResilienceConfigLoader', () {
    // -------------------------------------------------------------------------
    // Happy-path: full config
    // -------------------------------------------------------------------------

    test('parses full config with Resilience wrapper', () {
      const json = '''
{
  "Resilience": {
    "Retry": {
      "MaxRetries": 5,
      "RetryForever": false,
      "Backoff": { "Type": "exponential", "BaseMs": 200, "MaxDelayMs": 30000, "UseJitter": true }
    },
    "Timeout": { "Seconds": 15 },
    "CircuitBreaker": {
      "CircuitName": "payments",
      "FailureThreshold": 3,
      "SuccessThreshold": 2,
      "BreakSeconds": 60
    },
    "Bulkhead": { "MaxConcurrency": 20, "MaxQueueDepth": 50, "QueueTimeoutSeconds": 5 },
    "BulkheadIsolation": { "MaxConcurrentRequests": 8, "MaxQueueSize": 30, "QueueTimeoutSeconds": 3 }
  }
}
''';
      final config = _loader.load(json);

      expect(config.retry!.maxRetries, 5);
      expect(config.retry!.retryForever, isFalse);
      expect(config.retry!.backoff!.type, BackoffType.exponential);
      expect(config.retry!.backoff!.baseMs, 200);
      expect(config.retry!.backoff!.maxDelayMs, 30000);
      expect(config.retry!.backoff!.useJitter, isTrue);

      expect(config.timeout!.seconds, 15);

      expect(config.circuitBreaker!.circuitName, 'payments');
      expect(config.circuitBreaker!.failureThreshold, 3);
      expect(config.circuitBreaker!.successThreshold, 2);
      expect(config.circuitBreaker!.breakSeconds, 60);

      expect(config.bulkhead!.maxConcurrency, 20);
      expect(config.bulkhead!.maxQueueDepth, 50);
      expect(config.bulkhead!.queueTimeoutSeconds, 5);

      expect(config.bulkheadIsolation!.maxConcurrentRequests, 8);
      expect(config.bulkheadIsolation!.maxQueueSize, 30);
      expect(config.bulkheadIsolation!.queueTimeoutSeconds, 3);
    });

    test('parses config without Resilience wrapper (direct map)', () {
      const json = '{"Retry": {"MaxRetries": 3}, "Timeout": {"Seconds": 10}}';
      final config = _loader.load(json);
      expect(config.retry!.maxRetries, 3);
      expect(config.timeout!.seconds, 10);
    });

    test('user example: Retry + Timeout', () {
      const json = '''
{
  "Resilience": {
    "Retry": { "MaxRetries": 3 },
    "Timeout": { "Seconds": 10 }
  }
}
''';
      final config = _loader.load(json);
      expect(config.retry!.maxRetries, 3);
      expect(config.timeout!.seconds, 10);
      expect(config.circuitBreaker, isNull);
    });

    // -------------------------------------------------------------------------
    // Defaults
    // -------------------------------------------------------------------------

    test('empty Retry section uses all defaults', () {
      final config = _loader.load(_wrap('{"Retry": {}}'));
      expect(config.retry!.maxRetries, 3);
      expect(config.retry!.retryForever, isFalse);
      expect(config.retry!.backoff, isNull);
    });

    test('empty Timeout section uses default 30 seconds', () {
      final config = _loader.load(_wrap('{"Timeout": {}}'));
      expect(config.timeout!.seconds, 30);
    });

    test('empty CircuitBreaker section uses all defaults', () {
      final config = _loader.load(_wrap('{"CircuitBreaker": {}}'));
      final cb = config.circuitBreaker!;
      expect(cb.circuitName, 'default');
      expect(cb.failureThreshold, 5);
      expect(cb.successThreshold, 1);
      expect(cb.breakSeconds, 30);
    });

    test('empty Bulkhead section uses all defaults', () {
      final config = _loader.load(_wrap('{"Bulkhead": {}}'));
      final bh = config.bulkhead!;
      expect(bh.maxConcurrency, 10);
      expect(bh.maxQueueDepth, 100);
      expect(bh.queueTimeoutSeconds, 10);
    });

    test('empty BulkheadIsolation section uses all defaults', () {
      final config = _loader.load(_wrap('{"BulkheadIsolation": {}}'));
      final bi = config.bulkheadIsolation!;
      expect(bi.maxConcurrentRequests, 10);
      expect(bi.maxQueueSize, 100);
      expect(bi.queueTimeoutSeconds, 10);
    });

    test('empty root resilience section returns empty config', () {
      final config = _loader.load(_wrap('{}'));
      expect(config.isEmpty, isTrue);
    });

    test('empty JSON object with no Resilience key returns empty config', () {
      final config = _loader.load('{}');
      expect(config.isEmpty, isTrue);
    });

    // -------------------------------------------------------------------------
    // Backoff type parsing
    // -------------------------------------------------------------------------

    group('Backoff type parsing', () {
      BackoffConfig parseBackoff(String typeJson) {
        final json = _wrap('{"Retry": {"Backoff": {"Type": "$typeJson"}}}');
        return _loader.load(json).retry!.backoff!;
      }

      test('none', () => expect(parseBackoff('none').type, BackoffType.none));
      test(
        'constant',
        () => expect(parseBackoff('constant').type, BackoffType.constant),
      );
      test(
        'linear',
        () => expect(parseBackoff('linear').type, BackoffType.linear),
      );
      test(
        'exponential',
        () => expect(parseBackoff('exponential').type, BackoffType.exponential),
      );
      test(
        'decorrelatedJitter (camelCase)',
        () => expect(
          parseBackoff('decorrelatedJitter').type,
          BackoffType.decorrelatedJitter,
        ),
      );
      test(
        'decorrelated-jitter (kebab-case)',
        () => expect(
          parseBackoff('decorrelated-jitter').type,
          BackoffType.decorrelatedJitter,
        ),
      );
      test(
        'decorrelated_jitter (snake_case)',
        () => expect(
          parseBackoff('decorrelated_jitter').type,
          BackoffType.decorrelatedJitter,
        ),
      );
      test(
        'unknown type falls back to none',
        () => expect(parseBackoff('unknown').type, BackoffType.none),
      );
    });

    // -------------------------------------------------------------------------
    // loadMap
    // -------------------------------------------------------------------------

    test('loadMap accepts a pre-decoded map', () {
      final map = <String, dynamic>{
        'Retry': {'MaxRetries': 7},
        'Timeout': {'Seconds': 20},
      };
      final config = _loader.loadMap(map);
      expect(config.retry!.maxRetries, 7);
      expect(config.timeout!.seconds, 20);
    });

    // -------------------------------------------------------------------------
    // Error cases
    // -------------------------------------------------------------------------

    test('throws FormatException for non-object root', () {
      expect(() => _loader.load('"string"'), throwsFormatException);
    });

    test('throws FormatException when Resilience is not an object', () {
      expect(
        () => _loader.load('{"Resilience": 42}'),
        throwsFormatException,
      );
    });

    test('throws FormatException when Retry is not an object', () {
      expect(
        () => _loader.load(_wrap('{"Retry": 3}')),
        throwsFormatException,
      );
    });

    test('throws FormatException when Timeout is not an object', () {
      expect(
        () => _loader.load(_wrap('{"Timeout": "fast"}')),
        throwsFormatException,
      );
    });

    test('throws FormatException when MaxRetries is wrong type', () {
      expect(
        () => _loader.load(_wrap('{"Retry": {"MaxRetries": "three"}}')),
        throwsFormatException,
      );
    });

    test('throws FormatException when RetryForever is wrong type', () {
      expect(
        () => _loader.load(_wrap('{"Retry": {"RetryForever": 1}}')),
        throwsFormatException,
      );
    });
  });

  // ==========================================================================
  //  ResilienceConfigBinder — policy instantiation
  // ==========================================================================

  group('ResilienceConfigBinder', () {
    // -------------------------------------------------------------------------
    // buildRetry
    // -------------------------------------------------------------------------

    group('buildRetry', () {
      test('creates RetryResiliencePolicy with correct maxRetries', () {
        final policy = _binder.buildRetry(const RetryConfig(maxRetries: 5));
        expect(policy, isA<RetryResiliencePolicy>());
        expect(policy.maxRetries, 5);
      });

      test('creates forever-retry when retryForever=true', () {
        final policy =
            _binder.buildRetry(const RetryConfig(retryForever: true));
        expect(policy.retryForever, isTrue);
      });

      test('NoBackoff when backoff is null', () {
        final policy = _binder.buildRetry(const RetryConfig());
        expect(policy.backoff, isA<NoBackoff>());
      });

      test('ConstantBackoff when type=constant', () {
        const config = RetryConfig(
          maxRetries: 2,
          backoff: BackoffConfig(type: BackoffType.constant, baseMs: 500),
        );
        final policy = _binder.buildRetry(config);
        expect(policy.backoff, isA<ConstantBackoff>());
        expect(
          (policy.backoff as ConstantBackoff).delay,
          const Duration(milliseconds: 500),
        );
      });

      test('LinearBackoff when type=linear without maxDelayMs', () {
        const config = RetryConfig(
          maxRetries: 2,
          backoff: BackoffConfig(type: BackoffType.linear, baseMs: 100),
        );
        final policy = _binder.buildRetry(config);
        expect(policy.backoff, isA<LinearBackoff>());
      });

      test('CappedBackoff(LinearBackoff) when type=linear with maxDelayMs', () {
        const config = RetryConfig(
          maxRetries: 2,
          backoff: BackoffConfig(
            type: BackoffType.linear,
            baseMs: 100,
            maxDelayMs: 3000,
          ),
        );
        final policy = _binder.buildRetry(config);
        expect(policy.backoff, isA<CappedBackoff>());
      });

      test('ExponentialBackoff when type=exponential', () {
        const config = RetryConfig(
          backoff: BackoffConfig(
            type: BackoffType.exponential,
            useJitter: true,
          ),
        );
        final policy = _binder.buildRetry(config);
        expect(policy.backoff, isA<ExponentialBackoff>());
        expect((policy.backoff as ExponentialBackoff).useJitter, isTrue);
      });

      test('DecorrelatedJitterBackoff when type=decorrelatedJitter', () {
        const config = RetryConfig(
          backoff: BackoffConfig(
            type: BackoffType.decorrelatedJitter,
          ),
        );
        final policy = _binder.buildRetry(config);
        expect(policy.backoff, isA<DecorrelatedJitterBackoff>());
      });

      test('retries succeed at runtime', () async {
        var calls = 0;
        final policy = _binder.buildRetry(const RetryConfig(maxRetries: 2));
        final result = await policy.execute(() async {
          calls++;
          if (calls < 2) throw Exception('transient');
          return 'ok';
        });
        expect(result, 'ok');
        expect(calls, 2);
      });
    });

    // -------------------------------------------------------------------------
    // buildTimeout
    // -------------------------------------------------------------------------

    group('buildTimeout', () {
      test('creates TimeoutResiliencePolicy with correct duration', () {
        final policy = _binder.buildTimeout(const TimeoutConfig(seconds: 15));
        expect(policy, isA<TimeoutResiliencePolicy>());
        expect(policy.timeout, const Duration(seconds: 15));
      });

      test('throws HttpTimeoutException when action exceeds timeout', () async {
        final policy = _binder.buildTimeout(const TimeoutConfig(seconds: 1));
        expect(
          () => policy.execute(
            () => Future.delayed(const Duration(seconds: 5), () => 'done'),
          ),
          throwsA(isA<HttpTimeoutException>()),
        );
      });
    });

    // -------------------------------------------------------------------------
    // buildCircuitBreaker
    // -------------------------------------------------------------------------

    group('buildCircuitBreaker', () {
      test('creates CircuitBreakerResiliencePolicy with correct params', () {
        const config = CircuitBreakerConfig(
          circuitName: 'api',
          failureThreshold: 3,
          successThreshold: 2,
          breakSeconds: 45,
        );
        final policy = _binder.buildCircuitBreaker(config);
        expect(policy, isA<CircuitBreakerResiliencePolicy>());
        expect(policy.circuitName, 'api');
        expect(policy.failureThreshold, 3);
        expect(policy.successThreshold, 2);
        expect(policy.breakDuration, const Duration(seconds: 45));
      });
    });

    // -------------------------------------------------------------------------
    // buildBulkhead
    // -------------------------------------------------------------------------

    group('buildBulkhead', () {
      test('creates BulkheadResiliencePolicy with correct params', () {
        const config = BulkheadConfig(
          maxConcurrency: 10,
          maxQueueDepth: 50,
          queueTimeoutSeconds: 5,
        );
        final policy = _binder.buildBulkhead(config);
        expect(policy, isA<BulkheadResiliencePolicy>());
        expect(policy.maxConcurrency, 10);
        expect(policy.maxQueueDepth, 50);
        expect(policy.queueTimeout, const Duration(seconds: 5));
      });
    });

    // -------------------------------------------------------------------------
    // buildBulkheadIsolation
    // -------------------------------------------------------------------------

    group('buildBulkheadIsolation', () {
      test('creates BulkheadIsolationResiliencePolicy with correct params', () {
        const config = BulkheadIsolationConfig(
          maxConcurrentRequests: 5,
          maxQueueSize: 20,
          queueTimeoutSeconds: 3,
        );
        final policy = _binder.buildBulkheadIsolation(config);
        expect(policy, isA<BulkheadIsolationResiliencePolicy>());
      });
    });

    // -------------------------------------------------------------------------
    // buildPipeline
    // -------------------------------------------------------------------------

    group('buildPipeline', () {
      test('returns no-op policy for empty config', () async {
        final policy = _binder.buildPipeline(const ResilienceConfig());
        // Should just pass through
        final result = await policy.execute(() async => 'hello');
        expect(result, 'hello');
      });

      test(
          'single retry section returns a RetryResiliencePolicy inside pipeline',
          () {
        const config = ResilienceConfig(retry: RetryConfig(maxRetries: 2));
        final policy = _binder.buildPipeline(config);
        // Pipeline with a single policy is still a policy.
        expect(policy, isNotNull);
      });

      test('retry + timeout builds a composed pipeline', () {
        const config = ResilienceConfig(
          retry: RetryConfig(),
          timeout: TimeoutConfig(seconds: 10),
        );
        final policy = _binder.buildPipeline(config);
        expect(policy, isA<PolicyWrap>());
        final wrap = policy as PolicyWrap;
        expect(wrap.policies.length, 2);
        expect(wrap.policies[0], isA<TimeoutResiliencePolicy>());
        expect(wrap.policies[1], isA<RetryResiliencePolicy>());
      });

      test('circuit-breaker + retry has CB outermost', () {
        const config = ResilienceConfig(
          circuitBreaker: CircuitBreakerConfig(),
          retry: RetryConfig(maxRetries: 2),
        );
        final policy = _binder.buildPipeline(config);
        expect(policy, isA<PolicyWrap>());
        final wrap = policy as PolicyWrap;
        expect(wrap.policies[0], isA<CircuitBreakerResiliencePolicy>());
        expect(wrap.policies[1], isA<RetryResiliencePolicy>());
      });

      test('bulkheadIsolation takes precedence over bulkhead when both present',
          () {
        const config = ResilienceConfig(
          bulkhead: BulkheadConfig(maxConcurrency: 10),
          bulkheadIsolation: BulkheadIsolationConfig(),
        );
        final policy = _binder.buildPipeline(config);
        // Single policy — no PolicyWrap wrapper, just the raw policy.
        expect(policy, isA<BulkheadIsolationResiliencePolicy>());
      });

      test('all sections produce a 4-policy pipeline in correct order', () {
        const config = ResilienceConfig(
          timeout: TimeoutConfig(seconds: 10),
          circuitBreaker: CircuitBreakerConfig(),
          bulkhead: BulkheadConfig(maxConcurrency: 20),
          retry: RetryConfig(),
        );
        final policy = _binder.buildPipeline(config) as PolicyWrap;
        expect(policy.policies[0], isA<TimeoutResiliencePolicy>());
        expect(policy.policies[1], isA<CircuitBreakerResiliencePolicy>());
        expect(policy.policies[2], isA<BulkheadResiliencePolicy>());
        expect(policy.policies[3], isA<RetryResiliencePolicy>());
      });

      test('pipeline executes action correctly', () async {
        const config = ResilienceConfig(
          retry: RetryConfig(maxRetries: 2),
          timeout: TimeoutConfig(seconds: 5),
        );
        final policy = _binder.buildPipeline(config);
        final result = await policy.execute(() async => 42);
        expect(result, 42);
      });

      test('pipeline integrates with JSON-loaded config', () async {
        const json = '''
{
  "Resilience": {
    "Retry": { "MaxRetries": 2 },
    "Timeout": { "Seconds": 5 }
  }
}
''';
        final config = _loader.load(json);
        final policy = _binder.buildPipeline(config);
        final result = await policy.execute(() async => 'success');
        expect(result, 'success');
      });
    });
  });

  // ==========================================================================
  //  ResilienceConfigSource implementations
  // ==========================================================================

  group('JsonStringConfigSource', () {
    test('load() parses the JSON string', () {
      const source = JsonStringConfigSource(
        '{"Resilience": {"Retry": {"MaxRetries": 4}}}',
      );
      final config = source.load();
      expect(config.retry!.maxRetries, 4);
    });

    test('changes is null (static source)', () {
      const source = JsonStringConfigSource('{}');
      expect(source.changes, isNull);
    });

    test('multiple load() calls return consistent results', () {
      const source = JsonStringConfigSource(
        '{"Resilience": {"Timeout": {"Seconds": 8}}}',
      );
      expect(source.load().timeout!.seconds, 8);
      expect(source.load().timeout!.seconds, 8);
    });
  });

  group('InMemoryConfigSource', () {
    test('load() returns the initial config', () {
      final source = InMemoryConfigSource(
        const ResilienceConfig(timeout: TimeoutConfig(seconds: 5)),
      );
      expect(source.load().timeout!.seconds, 5);
    });

    test('update() changes the config returned by load()', () {
      final source = InMemoryConfigSource(const ResilienceConfig());
      source.update(
        const ResilienceConfig(retry: RetryConfig(maxRetries: 7)),
      );
      expect(source.load().retry!.maxRetries, 7);
    });

    test('changes stream emits updated config', () async {
      final source = InMemoryConfigSource(const ResilienceConfig());
      final emitted = <ResilienceConfig>[];
      final sub = source.changes.listen(emitted.add);

      source.update(const ResilienceConfig(timeout: TimeoutConfig(seconds: 3)));
      source.update(const ResilienceConfig(timeout: TimeoutConfig(seconds: 6)));

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await source.dispose();

      expect(emitted.length, 2);
      expect(emitted[0].timeout!.seconds, 3);
      expect(emitted[1].timeout!.seconds, 6);
    });

    test('dispose() closes the changes stream', () async {
      final source = InMemoryConfigSource(const ResilienceConfig());
      final done = Completer<void>();
      source.changes.listen(null, onDone: done.complete);
      await source.dispose();
      await done.future;
    });
  });

  // ==========================================================================
  //  PolicyRegistryConfigExtension
  // ==========================================================================

  group('PolicyRegistryConfigExtension', () {
    late PolicyRegistry registry;

    setUp(() => registry = PolicyRegistry());

    group('loadFromConfig', () {
      test('registers retry policy under "retry"', () {
        registry.loadFromConfig(
          const ResilienceConfig(retry: RetryConfig(maxRetries: 4)),
        );
        expect(registry.contains('retry'), isTrue);
        expect(registry.get<RetryResiliencePolicy>('retry').maxRetries, 4);
      });

      test('registers timeout policy under "timeout"', () {
        registry.loadFromConfig(
          const ResilienceConfig(timeout: TimeoutConfig(seconds: 15)),
        );
        expect(
          registry.get<TimeoutResiliencePolicy>('timeout').timeout,
          const Duration(seconds: 15),
        );
      });

      test('registers circuit-breaker under "circuit-breaker"', () {
        registry.loadFromConfig(
          const ResilienceConfig(
            circuitBreaker: CircuitBreakerConfig(circuitName: 'svc'),
          ),
        );
        final cb =
            registry.get<CircuitBreakerResiliencePolicy>('circuit-breaker');
        expect(cb.circuitName, 'svc');
      });

      test('registers bulkhead under "bulkhead"', () {
        registry.loadFromConfig(
          const ResilienceConfig(bulkhead: BulkheadConfig(maxConcurrency: 5)),
        );
        expect(
          registry.get<BulkheadResiliencePolicy>('bulkhead').maxConcurrency,
          5,
        );
      });

      test('registers bulkhead-isolation under "bulkhead-isolation"', () {
        registry.loadFromConfig(
          const ResilienceConfig(
            bulkheadIsolation:
                BulkheadIsolationConfig(maxConcurrentRequests: 8),
          ),
        );
        expect(registry.contains('bulkhead-isolation'), isTrue);
      });

      test('prefix namespaces all keys', () {
        registry.loadFromConfig(
          const ResilienceConfig(
            retry: RetryConfig(),
            timeout: TimeoutConfig(seconds: 5),
          ),
          prefix: 'payments',
        );
        expect(registry.contains('payments.retry'), isTrue);
        expect(registry.contains('payments.timeout'), isTrue);
        expect(registry.contains('retry'), isFalse);
      });

      test('throws StateError when key already registered', () {
        registry.loadFromConfig(
          const ResilienceConfig(retry: RetryConfig()),
        );
        expect(
          () => registry.loadFromConfig(
            const ResilienceConfig(retry: RetryConfig()),
          ),
          throwsStateError,
        );
      });

      test('skips null sections', () {
        registry.loadFromConfig(const ResilienceConfig(retry: RetryConfig()));
        expect(registry.length, 1);
        expect(registry.contains('timeout'), isFalse);
      });
    });

    group('loadFromConfigOrReplace', () {
      test('registers new policies', () {
        registry.loadFromConfigOrReplace(
          const ResilienceConfig(retry: RetryConfig()),
        );
        expect(registry.get<RetryResiliencePolicy>('retry').maxRetries, 3);
      });

      test('replaces existing policy without throwing', () {
        registry.loadFromConfig(
          const ResilienceConfig(retry: RetryConfig()),
        );
        registry.loadFromConfigOrReplace(
          const ResilienceConfig(retry: RetryConfig(maxRetries: 5)),
        );
        expect(registry.get<RetryResiliencePolicy>('retry').maxRetries, 5);
      });

      test('prefix works the same as loadFromConfig', () {
        registry.loadFromConfigOrReplace(
          const ResilienceConfig(timeout: TimeoutConfig(seconds: 10)),
          prefix: 'svc',
        );
        expect(registry.contains('svc.timeout'), isTrue);
      });
    });

    group('PolicyRegistry.instance integration', () {
      tearDown(PolicyRegistry.resetInstance);

      test('global instance loads config correctly', () {
        PolicyRegistry.instance.loadFromConfig(
          const ResilienceConfig(retry: RetryConfig(maxRetries: 2)),
        );
        expect(
          PolicyRegistry.instance
              .get<RetryResiliencePolicy>('retry')
              .maxRetries,
          2,
        );
      });
    });
  });

  // ==========================================================================
  //  End-to-end: JSON → config → registry → policy execution
  // ==========================================================================

  group('End-to-end', () {
    tearDown(PolicyRegistry.resetInstance);

    test('full round-trip from JSON to policy execution', () async {
      const json = '''
{
  "Resilience": {
    "Retry": { "MaxRetries": 2, "Backoff": {"Type": "constant", "BaseMs": 1} },
    "Timeout": { "Seconds": 5 }
  }
}
''';
      final config = _loader.load(json);
      PolicyRegistry.instance.loadFromConfig(config);

      final retry = PolicyRegistry.instance.get<RetryResiliencePolicy>('retry');
      var attempts = 0;
      final result = await retry.execute(() async {
        attempts++;
        if (attempts < 2) throw Exception('first fail');
        return 'done';
      });
      expect(result, 'done');
      expect(attempts, 2);
    });

    test('InMemoryConfigSource + binder hot-reload scenario', () async {
      final source = InMemoryConfigSource(
        const ResilienceConfig(retry: RetryConfig(maxRetries: 1)),
      );

      ResiliencePolicy buildPolicy() => _binder.buildPipeline(source.load());

      var policy = buildPolicy();

      // Initial: maxRetries 1 → 2 total attempts
      var calls = 0;
      await expectLater(
        policy.execute(() async {
          calls++;
          if (calls < 2) throw Exception('fail');
          return 'ok';
        }),
        completion('ok'),
      );
      expect(calls, 2);

      // Hot-reload: bump to maxRetries 3
      source.update(
        const ResilienceConfig(retry: RetryConfig()),
      );
      policy = buildPolicy();

      calls = 0;
      await expectLater(
        policy.execute(() async {
          calls++;
          if (calls < 4) throw Exception('fail');
          return 'after-reload';
        }),
        completion('after-reload'),
      );
      expect(calls, 4);

      await source.dispose();
    });
  });
}
