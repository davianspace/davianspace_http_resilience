import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

void main() {
  group('RetryPolicy', () {
    test('constant returns same delay every attempt', () {
      final policy = RetryPolicy.constant(
        maxRetries: 3,
        delay: const Duration(milliseconds: 100),
      );
      expect(policy.delayProvider(1), const Duration(milliseconds: 100));
      expect(policy.delayProvider(3), const Duration(milliseconds: 100));
    });

    test('linear scales delay by attempt', () {
      final policy = RetryPolicy.linear(
        maxRetries: 3,
        baseDelay: const Duration(milliseconds: 100),
      );
      expect(policy.delayProvider(1), const Duration(milliseconds: 100));
      expect(policy.delayProvider(2), const Duration(milliseconds: 200));
      expect(policy.delayProvider(3), const Duration(milliseconds: 300));
    });

    test('exponential doubles delay per attempt', () {
      final policy = RetryPolicy.exponential(
        maxRetries: 4,
        baseDelay: const Duration(milliseconds: 100),
      );
      expect(policy.delayProvider(1).inMilliseconds, 100);
      expect(policy.delayProvider(2).inMilliseconds, 200);
      expect(policy.delayProvider(3).inMilliseconds, 400);
    });

    test('exponential respects maxDelay', () {
      final policy = RetryPolicy.exponential(
        maxRetries: 10,
        baseDelay: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 1),
      );
      for (var i = 1; i <= 10; i++) {
        expect(
          policy.delayProvider(i).inMilliseconds,
          lessThanOrEqualTo(1000),
        );
      }
    });

    test('default shouldRetry returns true for 5xx', () {
      final policy = RetryPolicy.constant(maxRetries: 2);
      final ctx = _makeContext();
      expect(
        policy.shouldRetry(const HttpResponse(statusCode: 503), null, ctx),
        isTrue,
      );
    });

    test('default shouldRetry returns false for 2xx', () {
      final policy = RetryPolicy.constant(maxRetries: 2);
      final ctx = _makeContext();
      expect(policy.shouldRetry(HttpResponse.ok(), null, ctx), isFalse);
    });

    test('default shouldRetry returns true for exceptions', () {
      final policy = RetryPolicy.constant(maxRetries: 2);
      final ctx = _makeContext();
      expect(
        policy.shouldRetry(null, Exception('network error'), ctx),
        isTrue,
      );
    });
  });

  group('CircuitBreakerPolicy & CircuitBreakerState', () {
    late CircuitBreakerPolicy policy;
    late CircuitBreakerState state;

    setUp(() {
      policy = const CircuitBreakerPolicy(
        circuitName: 'test-circuit',
        failureThreshold: 3,
        breakDuration: Duration(seconds: 60),
      );
      state = CircuitBreakerState(policy: policy);
    });

    test('starts in closed state', () {
      expect(state.state, CircuitState.closed);
    });

    test('opens after failureThreshold consecutive failures', () {
      for (var i = 0; i < 3; i++) {
        state.recordFailure();
      }
      expect(state.state, CircuitState.open);
    });

    test('does not allow requests when open', () {
      for (var i = 0; i < 3; i++) {
        state.recordFailure();
      }
      expect(state.isAllowing, isFalse);
    });

    test('success in closed state resets failure counter', () {
      state.recordFailure();
      state.recordFailure();
      state.recordSuccess();
      // Still needs 3 failures to open
      state.recordFailure();
      state.recordFailure();
      expect(state.state, CircuitState.closed);
    });

    test('reset returns circuit to closed', () {
      for (var i = 0; i < 3; i++) {
        state.recordFailure();
      }
      state.reset();
      expect(state.state, CircuitState.closed);
      expect(state.isAllowing, isTrue);
    });
  });

  group('TimeoutPolicy', () {
    test('stores timeout correctly', () {
      const policy = TimeoutPolicy(timeout: Duration(seconds: 5));
      expect(policy.timeout, const Duration(seconds: 5));
      expect(policy.perRetry, isFalse);
    });

    test('perRetry flag is stored', () {
      const policy = TimeoutPolicy(
        timeout: Duration(seconds: 3),
        perRetry: true,
      );
      expect(policy.perRetry, isTrue);
    });
  });

  group('BulkheadPolicy', () {
    test('default values are sensible', () {
      const policy = BulkheadPolicy();
      expect(policy.maxConcurrency, 10);
      expect(policy.maxQueueDepth, 100);
    });

    test('custom values are stored', () {
      const policy = BulkheadPolicy(
        maxConcurrency: 5,
        maxQueueDepth: 20,
        queueTimeout: Duration(seconds: 5),
      );
      expect(policy.maxConcurrency, 5);
      expect(policy.maxQueueDepth, 20);
      expect(policy.queueTimeout, const Duration(seconds: 5));
    });
  });
}

HttpContext _makeContext() => HttpContext(
      request: HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
      ),
    );
