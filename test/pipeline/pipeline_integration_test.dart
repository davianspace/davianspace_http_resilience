// ignore_for_file: lines_longer_than_80_chars

import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test doubles
// ════════════════════════════════════════════════════════════════════════════

/// A [DelegatingHandler] that records every entry/exit and optionally
/// allows the test to control what happens at each call index.
final class _AuditHandler extends DelegatingHandler {
  _AuditHandler(this.name, this._log);

  final String name;
  final List<String> _log;
  int _callIndex = 0;

  // If set, the Nth call returns this status instead of forwarding.
  final Map<int, int> shortCircuitOnCall = {};

  @override
  Future<HttpResponse> send(HttpContext context) async {
    final idx = _callIndex++;
    _log.add('$name.enter[$idx]');
    if (shortCircuitOnCall.containsKey(idx)) {
      final status = shortCircuitOnCall[idx]!;
      _log.add('$name.shortCircuit[$idx]→$status');
      return HttpResponse(statusCode: status);
    }
    final response = await innerHandler.send(context);
    _log.add('$name.exit[$idx]→${response.statusCode}');
    return response;
  }
}

/// A handler that throws unconditionally.
final class _ThrowingHandler extends DelegatingHandler {
  _ThrowingHandler(this._error);

  final Object _error;

  @override
  Future<HttpResponse> send(HttpContext context) => Future.error(_error);
}

// Creates a mock http.Client that always responds with [status].
http.Client _mockClient(int status) => http_testing.MockClient(
      (_) async => http.Response('', status),
    );

// Creates an HttpContext pointing at a minimal URL.
HttpContext _ctx() => HttpContext(
      request: HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://example.com/test'),
      ),
    );

// ════════════════════════════════════════════════════════════════════════════
//  Pipeline execution order
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('Pipeline execution order', () {
    test('handlers execute outer-first, return inner-first', () async {
      final log = <String>[];

      // Build:  outer → middle → inner → terminal(200)
      final inner = _AuditHandler('inner', log);
      final middle = _AuditHandler('middle', log);
      final outer = _AuditHandler('outer', log);

      // Wire manually so the test is independent of HttpPipelineBuilder.
      // (terminal variable removed — use NoOpPipeline directly)
      const alwaysOk = NoOpPipeline();

      inner.innerHandler = alwaysOk;
      middle.innerHandler = inner;
      outer.innerHandler = middle;

      await outer.send(_ctx());

      expect(log, [
        'outer.enter[0]',
        'middle.enter[0]',
        'inner.enter[0]',
        'inner.exit[0]→200',
        'middle.exit[0]→200',
        'outer.exit[0]→200',
      ]);
    });

    test('RetryHandler re-enters the inner pipeline on each attempt', () async {
      final log = <String>[];
      final innerAudit = _AuditHandler('inner', log);

      // Build a stack: RetryHandler(maxRetries=2) → innerAudit → fail twice, succeed third
      int callCount = 0;
      final terminal = _CustomHandler(() {
        callCount++;
        if (callCount < 3) return Future.error(Exception('transient'));
        return Future.value(HttpResponse.ok());
      });

      innerAudit.innerHandler = terminal;

      final retryHandler = RetryHandler(
        RetryPolicy.constant(maxRetries: 3, delay: Duration.zero),
      );
      retryHandler.innerHandler = innerAudit;

      final response = await retryHandler.send(_ctx());
      expect(response.isSuccess, isTrue);
      // innerAudit must have been entered 3 times
      expect(
        log.where((e) => e.startsWith('inner.enter')).length,
        3,
        reason: 'inner pipeline must be re-entered for each retry attempt',
      );
    });

    test('FallbackHandler short-circuits and never calls inner on success',
        () async {
      final log = <String>[];
      final innerAudit = _AuditHandler('inner', log);
      innerAudit.innerHandler = const NoOpPipeline();

      final fallback = FallbackHandler(
        FallbackPolicy(
          fallbackAction: (_, __, ___) async => HttpResponse.ok(),
          // shouldHandle = null → no response-based trigger; inner succeeds anyway
        ),
      );
      fallback.innerHandler = innerAudit;

      final response = await fallback.send(_ctx());
      expect(response.isSuccess, isTrue);
      // inner must have executed (fallback not triggered)
      expect(log.where((e) => e.startsWith('inner.enter')).length, 1);
    });

    test('FallbackHandler intercepts error thrown by inner pipeline', () async {
      int fallbackCalls = 0;
      final throwing = _ThrowingHandler(Exception('inner failure'));

      final fallback = FallbackHandler(
        FallbackPolicy(
          fallbackAction: (_, __, ___) async {
            fallbackCalls++;
            return const HttpResponse(statusCode: 200);
          },
          // null shouldHandle → catches all exceptions
        ),
      );
      throwing.innerHandler = const NoOpPipeline(); // unused inner for thrower
      fallback.innerHandler = throwing;

      final response = await fallback.send(_ctx());
      expect(response.statusCode, 200);
      expect(fallbackCalls, 1);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  //  HttpClientFactory integration
  // ════════════════════════════════════════════════════════════════════════

  group('HttpClientBuilder — stacked policies execute in correct order', () {
    test('timeout is applied per-attempt inside retry', () async {
      // Retry(3) → Timeout(short) → slow server
      // Each attempt should time out individually;
      // we should get RetryExhaustedException with HttpTimeoutException as cause.
      int attemptCount = 0;

      final client = HttpClientBuilder('timeout-retry-test')
          .withRetry(
            RetryPolicy.constant(
              maxRetries: 2,
              delay: Duration.zero,
            ),
          )
          .withTimeout(const TimeoutPolicy(timeout: Duration(milliseconds: 10)))
          .withHttpClient(
            _SlowClient(
              delayMs: 200, // 200 ms >> 10 ms timeout
              onAttempt: () => attemptCount++,
            ),
          )
          .build();

      await expectLater(
        client.get(Uri.parse('https://example.com/slow')),
        throwsA(isA<RetryExhaustedException>()),
      );
      // Retry wraps timeout: expect 3 total attempts (1 + 2 retries)
      expect(attemptCount, 3);
    });

    test('circuit breaker opens after failures and blocks subsequent requests',
        () async {
      final registry = CircuitBreakerRegistry();
      const policy = CircuitBreakerPolicy(
        circuitName: 'cb-integration-test',
        failureThreshold: 2,
        breakDuration: Duration(seconds: 60),
      );

      final client = HttpClientBuilder('cb-builder-test')
          .withCircuitBreaker(policy, registry: registry)
          .withHttpClient(_mockClient(503))
          .build();

      // Two failures to trip the circuit
      await client.get(Uri.parse('/ping')).catchError((_) => HttpResponse.ok());
      await client.get(Uri.parse('/ping')).catchError((_) => HttpResponse.ok());

      // Now circuit should be open
      await expectLater(
        client.get(Uri.parse('/ping')),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    test('bulkhead rejects immediately when at capacity and queue is zero',
        () async {
      final completer = Completer<http.Response>();

      // A client that blocks until completer completes.
      final blockingClient = http_testing.MockClient(
        (_) => completer.future,
      );

      final client = HttpClientBuilder('bulkhead-builder-test')
          .withBulkhead(
            const BulkheadPolicy(
              maxConcurrency: 1,
              maxQueueDepth: 0,
            ),
          )
          .withHttpClient(blockingClient)
          .build();

      // First request starts and blocks.
      final first = client.get(Uri.parse('/resource'));

      // Give the event loop a moment so the first request enters the bulkhead.
      await Future<void>.delayed(Duration.zero);

      // Second request should be rejected immediately.
      await expectLater(
        client.get(Uri.parse('/resource')),
        throwsA(isA<BulkheadRejectedException>()),
      );

      // Let first request finish.
      completer.complete(http.Response('', 200));
      final response = await first;
      expect(response.isSuccess, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  HttpStatusException hierarchy
  // ══════════════════════════════════════════════════════════════════════════

  group('HttpStatusException extends HttpResilienceException', () {
    test('ensureSuccess throws HttpStatusException for non-2xx', () {
      const response = HttpResponse(statusCode: 404);
      expect(
        response.ensureSuccess,
        throwsA(isA<HttpStatusException>()),
      );
    });

    test('HttpStatusException is also an HttpResilienceException', () {
      const response = HttpResponse(statusCode: 503);
      expect(
        response.ensureSuccess,
        throwsA(isA<HttpResilienceException>()),
      );
    });

    test('HttpStatusException carries status code and body', () {
      final ex = HttpStatusException(
        statusCode: 503,
        bodyBytes: 'Service Down'.codeUnits,
      );
      expect(ex.statusCode, 503);
      expect(ex.body, 'Service Down');
      expect(ex.message, contains('503'));
      expect(ex.message, contains('Service Down'));
    });

    test('HttpStatusException with no body produces compact message', () {
      final ex = HttpStatusException(statusCode: 401);
      expect(ex.message, 'HTTP 401');
    });

    test('HttpStatusException body is null when no bytes given', () {
      final ex = HttpStatusException(statusCode: 500);
      expect(ex.body, isNull);
    });

    test('HttpStatusException body is null for empty bytes', () {
      final ex = HttpStatusException(statusCode: 500, bodyBytes: []);
      expect(ex.body, isNull);
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════════
//  Helper test doubles
// ═══════════════════════════════════════════════════════════════════════════

/// A handler that delegates its [send] logic to a provided callback.
final class _CustomHandler extends DelegatingHandler {
  _CustomHandler(this._fn);
  final Future<HttpResponse> Function() _fn;

  @override
  Future<HttpResponse> send(HttpContext context) => _fn();
}

/// An http.Client that pauses for [delayMs] ms before responding 200.
final class _SlowClient extends http.BaseClient {
  _SlowClient({required this.delayMs, this.onAttempt});

  final int delayMs;
  final void Function()? onAttempt;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onAttempt?.call();
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return http.StreamedResponse(Stream.value(const []), 200);
  }
}
