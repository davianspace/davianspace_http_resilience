// Tests for PolicyRegistry(namespace:) added in Phase 7.2.
// Verifies that named sub-registries isolate their keys and that the public
// API (keys, toMap, toString, get, contains, remove, replace, tryGet)
// always returns logical names — i.e. without the internal namespace prefix.

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helper factory methods
// ════════════════════════════════════════════════════════════════════════════

RetryResiliencePolicy _retryPolicy([int maxRetries = 2]) =>
    Policy.retry(maxRetries: maxRetries);

CircuitBreakerResiliencePolicy _cbPolicy([String name = 'x']) =>
    Policy.circuitBreaker(circuitName: name);

TimeoutResiliencePolicy _timeoutPolicy() =>
    Policy.timeout(const Duration(seconds: 5));

// ════════════════════════════════════════════════════════════════════════════
//  No-namespace (backward compatibility)
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('PolicyRegistry — no namespace (default)', () {
    test('empty namespace preserves existing behaviour', () {
      final reg = PolicyRegistry()..add('retry', _retryPolicy());
      expect(reg.contains('retry'), isTrue);
      expect(reg.get<RetryResiliencePolicy>('retry'), isNotNull);
    });

    test('keys returns plain names', () {
      final reg = PolicyRegistry()
        ..add('a', _retryPolicy())
        ..add('b', _timeoutPolicy());
      expect(reg.keys, containsAll(['a', 'b']));
      expect(reg.keys.any((k) => k.contains(':')), isFalse);
    });

    test('toMap keys are plain names', () {
      final reg = PolicyRegistry()..add('p', _retryPolicy());
      expect(reg.toMap(), contains('p'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  With namespace
  // ──────────────────────────────────────────────────────────────────────────

  group('PolicyRegistry — with namespace', () {
    test('add/contains/get use logical name (without prefix)', () {
      final reg = PolicyRegistry(namespace: 'svc')
        ..add('retry', _retryPolicy());
      expect(reg.contains('retry'), isTrue);
      expect(reg.get<RetryResiliencePolicy>('retry'), isNotNull);
    });

    test('keys getter strips namespace prefix', () {
      final reg = PolicyRegistry(namespace: 'team')
        ..add('timeout', _timeoutPolicy())
        ..add('retry', _retryPolicy());
      expect(reg.keys, containsAll(['timeout', 'retry']));
      expect(reg.keys.any((k) => k.contains(':')), isFalse);
    });

    test('toMap keys are stripped of namespace prefix', () {
      final reg = PolicyRegistry(namespace: 'svc')..add('cb', _cbPolicy());
      final map = reg.toMap();
      expect(map, contains('cb'));
      expect(map.keys.any((k) => k.contains(':')), isFalse);
    });

    test('toString shows logical names without prefix', () {
      final reg = PolicyRegistry(namespace: 'x')
        ..add('my-policy', _retryPolicy());
      final str = reg.toString();
      expect(str, contains('"my-policy"'));
      expect(str, isNot(contains('x:my-policy')));
    });

    test('remove works with logical name', () {
      final reg = PolicyRegistry(namespace: 'ns')..add('p', _retryPolicy());
      reg.remove('p');
      expect(reg.contains('p'), isFalse);
    });

    test('replace works with logical name', () {
      final reg = PolicyRegistry(namespace: 'ns')..add('p', _retryPolicy(1));
      reg.replace('p', _retryPolicy(9));
      expect(reg.get<RetryResiliencePolicy>('p').maxRetries, 9);
    });

    test('tryGet returns null for absent key', () {
      final reg = PolicyRegistry(namespace: 'ns');
      expect(reg.tryGet<RetryResiliencePolicy>('absent'), isNull);
    });

    test('add throws StateError on duplicate logical name', () {
      final reg = PolicyRegistry(namespace: 'ns')..add('p', _retryPolicy(1));
      expect(
        () => reg.add('p', _retryPolicy()),
        throwsA(isA<StateError>()),
      );
    });

    test('addOrReplace does not throw on duplicate', () {
      final reg = PolicyRegistry(namespace: 'ns')..add('p', _retryPolicy(1));
      expect(
        () => reg.addOrReplace('p', _retryPolicy(5)),
        returnsNormally,
      );
      expect(reg.get<RetryResiliencePolicy>('p').maxRetries, 5);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Namespace isolation between registries
  // ──────────────────────────────────────────────────────────────────────────

  group('PolicyRegistry — namespace isolation', () {
    test('two registries with different namespaces do not share keys', () {
      final a = PolicyRegistry(namespace: 'a')..add('policy', _retryPolicy(1));
      final b = PolicyRegistry(namespace: 'b');
      expect(a.contains('policy'), isTrue);
      expect(b.contains('policy'), isFalse);
    });

    test('same logical name in different namespaces holds independent values',
        () {
      final a = PolicyRegistry(namespace: 'a')..add('p', _retryPolicy(1));
      final b = PolicyRegistry(namespace: 'b')..add('p', _retryPolicy(9));
      expect(a.get<RetryResiliencePolicy>('p').maxRetries, 1);
      expect(b.get<RetryResiliencePolicy>('p').maxRetries, 9);
    });

    test('no-namespace registry is isolated from namespaced registry', () {
      final plain = PolicyRegistry()..add('shared', _retryPolicy(1));
      final ns = PolicyRegistry(namespace: 'ns')..add('shared', _retryPolicy());
      expect(plain.get<RetryResiliencePolicy>('shared').maxRetries, 1);
      expect(ns.get<RetryResiliencePolicy>('shared').maxRetries, 2);
    });

    test('multiple policies in same namespace all accessible', () {
      final reg = PolicyRegistry(namespace: 'app')
        ..add('retry', _retryPolicy())
        ..add('timeout', _timeoutPolicy())
        ..add('cb', _cbPolicy());
      expect(reg.keys.toSet(), {'retry', 'timeout', 'cb'});
    });
  });
}
