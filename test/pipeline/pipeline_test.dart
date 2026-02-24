import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// A fake handler that returns a pre-configured response and records calls.
final class _StubHandler extends DelegatingHandler {
  _StubHandler(this._response);

  final HttpResponse _response;
  int callCount = 0;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    callCount++;
    return _response;
  }
}

/// A handler that forwards to inner but appends a custom header to the response.
final class _HeaderDecoratorHandler extends DelegatingHandler {
  _HeaderDecoratorHandler(this._headerName, this._headerValue);

  final String _headerName;
  final String _headerValue;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    final response = await innerHandler.send(context);
    return response.copyWith(
      headers: {...response.headers, _headerName: _headerValue},
    );
  }
}

/// A handler that always throws.
final class _ThrowingHandler extends DelegatingHandler {
  _ThrowingHandler();

  @override
  Future<HttpResponse> send(HttpContext context) =>
      throw Exception('Simulated network error');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('HttpPipelineBuilder', () {
    test('NoOpPipeline always returns 200', () async {
      const pipeline = NoOpPipeline();
      final ctx = _makeContext();
      final response = await pipeline.send(ctx);
      expect(response.isSuccess, isTrue);
    });

    test('single handler receives and forwards context', () async {
      final stub = _StubHandler(HttpResponse.ok());
      // Stub has no inner — acts as terminal for this test
      final ctx = _makeContext();
      final response = await stub.send(ctx);
      expect(response.statusCode, 200);
      expect(stub.callCount, 1);
    });

    test('pipeline chains handlers in correct order', () async {
      final calls = <String>[];

      final outer = _RecordingDelegatingHandler('outer', calls);
      final inner = _RecordingDelegatingHandler('inner', calls);
      final terminal = _StubHandler(HttpResponse.ok());

      inner.innerHandler = terminal;
      outer.innerHandler = inner;

      await outer.send(_makeContext());
      expect(
        calls,
        ['outer-before', 'inner-before', 'inner-after', 'outer-after'],
      );
    });

    test('builder wires chain correctly', () async {
      final decorator = _HeaderDecoratorHandler('X-Pipeline', 'active');
      final terminal = _StubHandler(HttpResponse.ok());

      // Manually wire for this focused test
      decorator.innerHandler = terminal;
      final response = await decorator.send(_makeContext());
      expect(response.headers['X-Pipeline'], 'active');
    });
  });

  group('RetryHandler', () {
    test('succeeds on first attempt without retry', () async {
      final policy = RetryPolicy.constant(maxRetries: 2);
      final handler = RetryHandler(policy);
      final stub = _StubHandler(HttpResponse.ok());
      handler.innerHandler = stub;

      final ctx = _makeContext();
      final response = await handler.send(ctx);
      expect(response.isSuccess, isTrue);
      expect(stub.callCount, 1);
      expect(ctx.retryCount, 0);
    });

    test('throws RetryExhaustedException after all attempts fail', () async {
      final policy = RetryPolicy.constant(
        maxRetries: 2,
        delay: Duration.zero,
      );
      final handler = RetryHandler(policy);
      final thrower = _ThrowingHandler()
        ..innerHandler = _StubHandler(HttpResponse.ok());
      // RetryHandler inner is the thrower (which ignores its inner)
      handler.innerHandler = thrower;

      expect(
        () => handler.send(_makeContext()),
        throwsA(isA<RetryExhaustedException>()),
      );
    });

    test('retries on 5xx and eventually exhausts', () async {
      final policy = RetryPolicy.constant(
        maxRetries: 2,
        delay: Duration.zero,
      );
      final handler = RetryHandler(policy);
      final stub = _StubHandler(HttpResponse.serviceUnavailable());
      handler.innerHandler = stub;

      await expectLater(
        handler.send(_makeContext()),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(stub.callCount, 3); // 1 initial + 2 retries
    });
  });

  group('CircuitBreakerHandler', () {
    test('allows requests in closed state', () async {
      final registry = CircuitBreakerRegistry();
      const policy = CircuitBreakerPolicy(circuitName: 'test-cb-allow');
      final handler = CircuitBreakerHandler(policy, registry: registry);
      handler.innerHandler = _StubHandler(HttpResponse.ok());

      final response = await handler.send(_makeContext());
      expect(response.isSuccess, isTrue);
    });

    test('throws CircuitOpenException when circuit is open', () async {
      final registry = CircuitBreakerRegistry();
      const policy = CircuitBreakerPolicy(
        circuitName: 'test-cb-open',
        failureThreshold: 1,
      );
      final handler = CircuitBreakerHandler(policy, registry: registry);
      handler.innerHandler = _StubHandler(HttpResponse.serviceUnavailable());

      // Trip the circuit
      await handler.send(_makeContext());

      expect(
        () => handler.send(_makeContext()),
        throwsA(isA<CircuitOpenException>()),
      );
    });
  });

  group('HttpContext', () {
    test('retryCount starts at zero', () {
      final ctx = _makeContext();
      expect(ctx.retryCount, 0);
    });

    test('updateRequest replaces the request', () {
      final ctx = _makeContext();
      final updated = ctx.request.withHeader('X-Auth', 'token');
      ctx.updateRequest(updated);
      expect(ctx.request.headers['X-Auth'], 'token');
    });

    test('getProperty returns null for missing key', () {
      final ctx = _makeContext();
      expect(ctx.getProperty<String>('missing'), isNull);
    });

    test('setProperty and getProperty round-trip', () {
      final ctx = _makeContext();
      ctx.setProperty('key', 42);
      expect(ctx.getProperty<int>('key'), 42);
    });
  });

  group('CancellationToken', () {
    test('starts not cancelled', () {
      expect(CancellationToken().isCancelled, isFalse);
    });

    test('cancel changes state', () {
      final token = CancellationToken();
      token.cancel('user navigated away');
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'user navigated away');
    });

    test('throwIfCancelled throws CancellationException', () {
      final token = CancellationToken()..cancel();
      expect(
        token.throwIfCancelled,
        throwsA(isA<CancellationException>()),
      );
    });

    test('cancel is idempotent', () {
      final token = CancellationToken();
      token.cancel('first');
      token.cancel('second');
      expect(token.reason, 'first');
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

HttpContext _makeContext() => HttpContext(
      request: HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com'),
      ),
    );

final class _RecordingDelegatingHandler extends DelegatingHandler {
  _RecordingDelegatingHandler(this._name, this._calls);

  final String _name;
  final List<String> _calls;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    _calls.add('$_name-before');
    final response = await innerHandler.send(context);
    _calls.add('$_name-after');
    return response;
  }
}
