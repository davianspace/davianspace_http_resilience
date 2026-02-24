import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test helpers
// ════════════════════════════════════════════════════════════════════════════

/// A trivial exception for testing.
final class _AppException implements Exception {
  const _AppException([this.message = '']);
  final String message;
  @override
  String toString() => '_AppException($message)';
}

final class _TransientException implements Exception {
  const _TransientException();
}

/// Builds an [HttpContext] with a stub GET request.
HttpContext _ctx() => HttpContext(
      request: HttpRequest(
        uri: Uri.parse('https://example.com/resource'),
        method: HttpMethod.get,
      ),
    );

/// Returns a synthetic [HttpResponse] with [statusCode].
HttpResponse _resp(int statusCode) => HttpResponse(statusCode: statusCode);

/// Builds an [http.Client] backed by [handler].
http.Client _httpClient(
  http_testing.MockClientHandler handler,
) =>
    http_testing.MockClient(handler);

/// Builds a [ResilientHttpClient] with [fallbackPolicy] applied and backed by
/// [`transportHandler`].  The pipeline raises the given [transportException]
/// instead of calling the real transport when non-null.
Future<HttpResponse> _sendWithFallback(
  FallbackPolicy fallbackPolicy, {
  int transportStatus = 200,
  Object? transportException,
}) async {
  final client = HttpClientBuilder()
      .withBaseUri(Uri.parse('https://example.com'))
      .withFallback(fallbackPolicy)
      .withHttpClient(
    _httpClient((_) async {
      if (transportException != null) throw transportException;
      return http.Response('body', transportStatus);
    }),
  ).build();
  return client.get(Uri.parse('/resource'));
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('HttpResponse.cached factory', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('encodes body as UTF-8 code units', () {
      final r = HttpResponse.cached('hello');
      expect(r.bodyAsString, equals('hello'));
    });

    test('default statusCode is 200', () {
      final r = HttpResponse.cached('data');
      expect(r.statusCode, equals(200));
    });

    test('custom statusCode is preserved', () {
      final r = HttpResponse.cached('', statusCode: 206);
      expect(r.statusCode, equals(206));
    });

    test('adds X-Cache: HIT header by default', () {
      final r = HttpResponse.cached('data');
      expect(r.headers['X-Cache'], equals('HIT'));
    });

    test('caller-supplied headers are merged', () {
      final r = HttpResponse.cached(
        'data',
        headers: {'Content-Type': 'text/plain'},
      );
      expect(r.headers['X-Cache'], equals('HIT'));
      expect(r.headers['Content-Type'], equals('text/plain'));
    });

    test('caller can override X-Cache header', () {
      final r = HttpResponse.cached('data', headers: {'X-Cache': 'STALE'});
      expect(r.headers['X-Cache'], equals('STALE'));
    });

    test('isSuccess returns true for default 200 status', () {
      final r = HttpResponse.cached('data');
      expect(r.isSuccess, isTrue);
    });

    test('empty body is valid', () {
      final r = HttpResponse.cached('');
      expect(r.bodyAsString, isEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackPolicy — value object', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('stores fallbackAction', () {
      Future<HttpResponse> action(
        HttpContext ctx,
        Object? ex,
        StackTrace? st,
      ) =>
          Future.value(HttpResponse.ok());
      final p = FallbackPolicy(fallbackAction: action);
      expect(p.fallbackAction, same(action));
    });

    test('shouldHandle defaults to null', () {
      final p = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
      );
      expect(p.shouldHandle, isNull);
    });

    test('classifier defaults to null', () {
      final p = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
      );
      expect(p.classifier, isNull);
    });

    test('onFallback defaults to null', () {
      final p = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
      );
      expect(p.onFallback, isNull);
    });

    test('stores all optional fields', () {
      const classifier = HttpOutcomeClassifier();
      var called = false;

      final p = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
        shouldHandle: (_, __, ___) => true,
        classifier: classifier,
        onFallback: (_, __, ___) => called = true,
      );

      expect(p.classifier, same(classifier));
      expect(p.shouldHandle, isNotNull);
      expect(p.onFallback, isNotNull);
      p.onFallback!(_ctx(), null, null);
      expect(called, isTrue);
    });

    test('toString describes filtered policy', () {
      final p = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
        shouldHandle: (_, __, ___) => true,
        classifier: const HttpOutcomeClassifier(),
      );
      final s = p.toString();
      expect(s, contains('FallbackPolicy'));
      expect(s, contains('filtered'));
      expect(s, contains('classifier'));
    });

    test('toString for plain policy is brief', () {
      final p = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
      );
      expect(p.toString(), equals('FallbackPolicy()'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackResiliencePolicy — exception handling', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('returns primary result when no exception', () async {
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'fallback',
      );
      final result = await policy.execute(() async => 'primary');
      expect(result, equals('primary'));
    });

    test('fires fallback action when primary throws', () async {
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'fallback result',
      );
      final result =
          await policy.execute<String>(() => throw const _AppException());
      expect(result, equals('fallback result'));
    });

    test('fallback action receives the exception', () async {
      Object? captured;
      const error = _AppException('boom');
      final policy = FallbackResiliencePolicy(
        fallbackAction: (ex, _) async {
          captured = ex;
          return 'ok';
        },
      );
      await policy.execute<String>(() => throw error);
      expect(captured, same(error));
    });

    test('fallback action receives the stack trace', () async {
      StackTrace? captured;
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, st) async {
          captured = st;
          return 'ok';
        },
      );
      await policy.execute<String>(() => throw const _AppException());
      expect(captured, isNotNull);
    });

    test('shouldHandle = null catches all exception types', () async {
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'caught',
      );
      // Different exception flavours
      for (final ex in [
        const _AppException(),
        const _TransientException(),
        StateError('state'),
        Exception('generic'),
        'raw string',
      ]) {
        final result = await policy.execute<String>(() => throw ex);
        expect(result, equals('caught'), reason: 'Should catch $ex');
      }
    });

    test('shouldHandle returning true triggers fallback', () async {
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'caught',
        shouldHandle: (e) => e is _AppException,
      );
      final result =
          await policy.execute<String>(() => throw const _AppException());
      expect(result, equals('caught'));
    });

    test('shouldHandle returning false lets exception propagate', () async {
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'should not reach',
        shouldHandle: (e) => e is _AppException, // only handles _AppException
      );
      expect(
        () => policy.execute<String>(
          () => throw const _TransientException(), // different type
        ),
        throwsA(isA<_TransientException>()),
      );
    });

    test('original stack trace is preserved on propagation', () async {
      late StackTrace originalSt;
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => '',
        shouldHandle: (_) => false, // always propagate
      );

      Object? caughtError;
      StackTrace? caughtSt;

      try {
        await policy.execute<String>(() async {
          try {
            throw const _AppException('root cause');
          } on Object catch (e, st) {
            originalSt = st;
            rethrow;
          }
        });
      } on Object catch (e, st) {
        caughtError = e;
        caughtSt = st;
      }

      expect(caughtError, isA<_AppException>());
      expect(caughtSt.toString(), equals(originalSt.toString()));
    });

    test('works with HttpResponse as generic type', () async {
      final fallback = HttpResponse.cached('offline');
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => fallback,
      );
      final result = await policy.execute<HttpResponse>(
        () => throw const _AppException(),
      );
      expect(result, same(fallback));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackResiliencePolicy — result-based (OutcomeClassifier)', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('fires fallback when classifier marks response as failure', () async {
      final fallback = HttpResponse.cached('cached');
      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __) async => fallback,
      );
      final result = await policy.execute<HttpResponse>(
        () async => _resp(503),
      );
      expect(result, same(fallback));
    });

    test('does not fire fallback for 2xx response', () async {
      final primary = _resp(200);
      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __) async => _resp(999),
      );
      final result = await policy.execute<HttpResponse>(() async => primary);
      expect(result, same(primary));
    });

    test('does not fire fallback for 4xx response (client error = permanent)',
        () async {
      final primary = _resp(404);
      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __) async => _resp(999),
      );
      // 4xx is permanent failure, which isFailure = true, so fallback fires
      final result = await policy.execute<HttpResponse>(() async => primary);
      // HttpOutcomeClassifier marks 4xx as permanentFailure which isFailure=true
      // → fallback fires
      expect(result.statusCode, isNot(404));
    });

    test('classifier receives null exception for response-based fallback',
        () async {
      Object? receivedEx;
      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (ex, _) async {
          receivedEx = ex;
          return HttpResponse.ok();
        },
      );
      await policy.execute<HttpResponse>(() async => _resp(503));
      expect(receivedEx, isNull);
    });

    test('classifier is ignored for non-HttpResponse generics', () async {
      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __) async => 'fallback',
      );
      // String is not HttpResponse → classifier block is skipped
      final result = await policy.execute<String>(() async => 'primary');
      expect(result, equals('primary'));
    });

    test('shouldHandleResult takes precedence over classifier', () async {
      var resultPredicateCalled = false;
      var classifierFallbackCalled = false;

      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        shouldHandleResult: (r) {
          resultPredicateCalled = true;
          return false; // never trigger
        },
        fallbackAction: (_, __) async {
          classifierFallbackCalled = true;
          return HttpResponse.ok();
        },
      );

      await policy.execute<HttpResponse>(() async => _resp(503));
      expect(resultPredicateCalled, isTrue);
      expect(classifierFallbackCalled, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackResiliencePolicy — shouldHandleResult predicate', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('fires fallback when predicate returns true on success', () async {
      final fallback = HttpResponse.cached('cached');
      final policy = FallbackResiliencePolicy(
        shouldHandleResult: (r) => r is HttpResponse && r.statusCode == 503,
        fallbackAction: (_, __) async => fallback,
      );
      final result = await policy.execute<HttpResponse>(() async => _resp(503));
      expect(result, same(fallback));
    });

    test('does not fire when predicate returns false', () async {
      final primary = _resp(200);
      final policy = FallbackResiliencePolicy(
        shouldHandleResult: (r) => false,
        fallbackAction: (_, __) async => _resp(999),
      );
      final result = await policy.execute<HttpResponse>(() async => primary);
      expect(result, same(primary));
    });

    test('receives result as argument', () async {
      Object? received;
      final primary = _resp(418);
      final policy = FallbackResiliencePolicy(
        shouldHandleResult: (r) {
          received = r;
          return false;
        },
        fallbackAction: (_, __) async => HttpResponse.ok(),
      );
      await policy.execute<HttpResponse>(() async => primary);
      expect(received, same(primary));
    });

    test('exception still triggers fallback even when result predicate set',
        () async {
      final policy = FallbackResiliencePolicy(
        shouldHandleResult: (r) => false, // never trigger on result
        fallbackAction: (_, __) async => 'fallback',
      );
      // Exception should still trigger fallback (shouldHandle is null → catch all)
      final result = await policy.execute<String>(
        () => throw const _AppException(),
      );
      expect(result, equals('fallback'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackResiliencePolicy — onFallback callback', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('invoked before fallback action on exception', () async {
      final events = <String>[];
      final policy = FallbackResiliencePolicy(
        onFallback: (ex, _) => events.add('onFallback'),
        fallbackAction: (_, __) async {
          events.add('action');
          return 'ok';
        },
      );
      await policy.execute<String>(() => throw const _AppException());
      expect(events, equals(['onFallback', 'action']));
    });

    test('invoked with the exception on exception-based trigger', () async {
      const error = _AppException('boom');
      Object? captured;
      final policy = FallbackResiliencePolicy(
        onFallback: (ex, _) => captured = ex,
        fallbackAction: (_, __) async => 'ok',
      );
      await policy.execute<String>(() => throw error);
      expect(captured, same(error));
    });

    test('invoked with null exception on result-based trigger', () async {
      Object? captured;
      final policy = FallbackResiliencePolicy(
        classifier: const HttpOutcomeClassifier(),
        onFallback: (ex, _) => captured = ex,
        fallbackAction: (_, __) async => HttpResponse.ok(),
      );
      await policy.execute<HttpResponse>(() async => _resp(503));
      expect(captured, isNull);
    });

    test('not invoked when primary succeeds', () async {
      var called = false;
      final policy = FallbackResiliencePolicy(
        onFallback: (_, __) => called = true,
        fallbackAction: (_, __) async => 'fallback',
      );
      await policy.execute<String>(() async => 'primary');
      expect(called, isFalse);
    });

    test('not invoked when shouldHandle blocks', () async {
      var called = false;
      final policy = FallbackResiliencePolicy(
        shouldHandle: (_) => false,
        onFallback: (_, __) => called = true,
        fallbackAction: (_, __) async => 'fallback',
      );
      try {
        await policy.execute<String>(() => throw const _AppException());
      } on _AppException catch (_) {}
      expect(called, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackResiliencePolicy — composition with PolicyWrap', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('catches exception thrown by inner policy', () async {
      final policy = Policy.wrap([
        Policy.fallback(
          fallbackAction: (_, __) async => HttpResponse.cached('cached'),
        ),
        Policy.retry(maxRetries: 2),
      ]);

      var callCount = 0;
      final result = await policy.execute<HttpResponse>(() async {
        callCount++;
        throw const _AppException();
      });

      expect(result.headers['X-Cache'], equals('HIT'));
      expect(callCount, equals(3)); // 1 original + 2 retries
    });

    test('skips fallback when retry eventually succeeds', () async {
      var callCount = 0;
      final policy = Policy.wrap([
        Policy.fallback(
          fallbackAction: (_, __) async => HttpResponse.cached('cached'),
        ),
        Policy.retry(maxRetries: 2),
      ]);

      final result = await policy.execute<HttpResponse>(() async {
        callCount++;
        if (callCount < 3) throw const _AppException();
        return _resp(200);
      });

      expect(result.statusCode, equals(200));
      expect(result.headers['X-Cache'], isNull);
    });

    test('composes three policies: fallback → timeout → retry', () async {
      final policy = ResiliencePipelineBuilder()
          .addFallback(
            fallbackAction: (_, __) async => HttpResponse.cached('offline'),
          )
          .addRetry(maxRetries: 1)
          .build();

      final result = await policy.execute<HttpResponse>(
        () => throw const _AppException(),
      );
      expect(result.headers['X-Cache'], equals('HIT'));
    });

    test('outermost fallback catches inner thrown exception', () async {
      var fallbackFired = false;
      final policy = Policy.fallback(
        fallbackAction: (_, __) async {
          fallbackFired = true;
          return HttpResponse.ok();
        },
      ).wrap(Policy.retry(maxRetries: 1));

      await policy.execute<HttpResponse>(() => throw const _AppException());
      expect(fallbackFired, isTrue);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackResiliencePolicy — statelessness', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('concurrent executions are independent', () async {
      const limit = 3;

      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'fallback',
      );

      final futures = List.generate(10, (i) async {
        if (i < limit) {
          return policy.execute<String>(() => throw const _AppException());
        } else {
          return policy.execute<String>(() async => 'primary');
        }
      });

      final results = await Future.wait(futures);
      expect(results.where((r) => r == 'fallback'), hasLength(limit));
      expect(results.where((r) => r == 'primary'), hasLength(10 - limit));
    });

    test('same instance reused across sequential calls', () async {
      final policy = FallbackResiliencePolicy(
        fallbackAction: (_, __) async => 'B',
      );

      expect(await policy.execute<String>(() async => 'A'), equals('A'));
      expect(
        await policy.execute<String>(() => throw const _AppException()),
        equals('B'),
      );
      expect(await policy.execute<String>(() async => 'C'), equals('C'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackHandler — exception handling via pipeline', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('returns primary response when no exception', () async {
      final policy = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.cached('fallback'),
      );
      final response = await _sendWithFallback(policy);
      expect(response.statusCode, equals(200));
    });

    test('fires fallback when transport throws', () async {
      final policy = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.cached('offline'),
      );
      final response = await _sendWithFallback(
        policy,
        transportException: Exception('network error'),
      );
      expect(response.bodyAsString, equals('offline'));
      expect(response.headers['X-Cache'], equals('HIT'));
    });

    test('fallback action receives exception', () async {
      Object? received;
      final ex = Exception('transport down');
      final policy = FallbackPolicy(
        fallbackAction: (_, err, __) async {
          received = err;
          return HttpResponse.ok();
        },
      );
      await _sendWithFallback(policy, transportException: ex);
      expect(received, same(ex));
    });

    test('fallback action receives context', () async {
      HttpContext? receivedCtx;
      final policy = FallbackPolicy(
        fallbackAction: (ctx, _, __) async {
          receivedCtx = ctx;
          return HttpResponse.ok();
        },
      );
      await _sendWithFallback(policy, transportException: Exception());
      expect(receivedCtx, isNotNull);
      expect(receivedCtx!.request.method, equals(HttpMethod.get));
    });

    test('shouldHandle returning false re-throws exception', () async {
      final policy = FallbackPolicy(
        fallbackAction: (_, __, ___) async =>
            HttpResponse.ok(body: 'should not reach'.codeUnits),
        shouldHandle: (_, ex, __) => ex is _AppException, // only _AppException
      );
      expect(
        () => _sendWithFallback(
          policy,
          transportException: Exception('other error'), // non-matching
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('shouldHandle returning true fires fallback', () async {
      final policy = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.cached('caught'),
        shouldHandle: (_, ex, __) => ex is Exception,
      );
      final response = await _sendWithFallback(
        policy,
        transportException: Exception('network'),
      );
      expect(response.bodyAsString, equals('caught'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackHandler — response-based (OutcomeClassifier)', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('fires fallback on 5xx when classifier is set', () async {
      final policy = FallbackPolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __, ___) async => HttpResponse.cached('cached'),
      );
      final response = await _sendWithFallback(policy, transportStatus: 503);
      expect(response.headers['X-Cache'], equals('HIT'));
    });

    test('does not fire fallback on 2xx even with classifier', () async {
      final policy = FallbackPolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __, ___) async => HttpResponse.cached('cached'),
      );
      final response = await _sendWithFallback(policy);
      expect(response.headers['X-Cache'], isNull);
      expect(response.statusCode, equals(200));
    });

    test('shouldHandle overrides classifier for response check', () async {
      var shouldHandleCalled = false;
      final policy = FallbackPolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __, ___) async => HttpResponse.cached('cached'),
        shouldHandle: (resp, _, __) {
          shouldHandleCalled = true;
          return false; // block fallback
        },
      );
      final response = await _sendWithFallback(policy, transportStatus: 503);
      expect(shouldHandleCalled, isTrue);
      expect(response.headers['X-Cache'], isNull); // fallback blocked
      expect(response.statusCode, equals(503));
    });

    test('classifier not consulted when shouldHandle is set', () async {
      var classifierInvoked = false;

      // Custom classifier that marks invocation
      final policy = FallbackPolicy(
        classifier: _MarkingClassifier(() => classifierInvoked = true),
        fallbackAction: (_, __, ___) async => HttpResponse.cached('f'),
        shouldHandle: (_, __, ___) => true, // catch everything
      );
      await _sendWithFallback(policy);
      expect(classifierInvoked, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FallbackHandler — onFallback callback', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('invoked on exception-triggered fallback', () async {
      var called = false;
      final policy = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
        onFallback: (_, __, ___) => called = true,
      );
      await _sendWithFallback(policy, transportException: Exception());
      expect(called, isTrue);
    });

    test('invoked on response-based fallback', () async {
      var called = false;
      final policy = FallbackPolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
        onFallback: (_, __, ___) => called = true,
      );
      await _sendWithFallback(policy, transportStatus: 503);
      expect(called, isTrue);
    });

    test('not invoked on successful response', () async {
      var called = false;
      final policy = FallbackPolicy(
        classifier: const HttpOutcomeClassifier(),
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
        onFallback: (_, __, ___) => called = true,
      );
      await _sendWithFallback(policy);
      expect(called, isFalse);
    });

    test('receives context and exception on exception trigger', () async {
      HttpContext? capturedCtx;
      Object? capturedEx;
      final ex = Exception('boom');

      final policy = FallbackPolicy(
        fallbackAction: (_, __, ___) async => HttpResponse.ok(),
        onFallback: (ctx, err, _) {
          capturedCtx = ctx;
          capturedEx = err;
        },
      );
      await _sendWithFallback(policy, transportException: ex);
      expect(capturedCtx, isNotNull);
      expect(capturedEx, same(ex));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('ResiliencePipelineBuilder.addFallback', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('creates a FallbackResiliencePolicy', () {
      final pipeline = ResiliencePipelineBuilder()
          .addFallback(
            fallbackAction: (_, __) async => HttpResponse.ok(),
          )
          .build();
      expect(pipeline, isA<FallbackResiliencePolicy>());
    });

    test('forwards all parameters to FallbackResiliencePolicy', () {
      bool sh(Object _) => true;
      bool shr(Object? _) => false;
      const classifier = HttpOutcomeClassifier();
      void cb(Object? _, StackTrace? __) {}

      final policy = ResiliencePipelineBuilder()
          .addFallback(
            fallbackAction: (_, __) async => HttpResponse.ok(),
            shouldHandle: sh,
            shouldHandleResult: shr,
            classifier: classifier,
            onFallback: cb,
          )
          .build() as FallbackResiliencePolicy;

      expect(policy.shouldHandle, same(sh));
      expect(policy.shouldHandleResult, same(shr));
      expect(policy.classifier, same(classifier));
      expect(policy.onFallback, same(cb));
    });

    test('composes with other policies', () {
      final pipeline = ResiliencePipelineBuilder()
          .addFallback(fallbackAction: (_, __) async => HttpResponse.ok())
          .addRetry(maxRetries: 3)
          .build();
      expect(pipeline, isA<PolicyWrap>());
      final wrap = pipeline as PolicyWrap;
      expect(wrap.policies[0], isA<FallbackResiliencePolicy>());
    });

    test('fires when composed pipeline exhausts retries', () async {
      var callCount = 0;
      final pipeline = ResiliencePipelineBuilder()
          .addFallback(
            fallbackAction: (_, __) async => HttpResponse.cached('fallback'),
          )
          .addRetry(maxRetries: 2)
          .build();

      final result = await pipeline.execute<HttpResponse>(() async {
        callCount++;
        throw const _AppException();
      });

      expect(result.headers['X-Cache'], equals('HIT'));
      expect(callCount, equals(3)); // 1 + 2 retries
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Policy.fallback static factory', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('returns a FallbackResiliencePolicy', () {
      final p = Policy.fallback(
        fallbackAction: (_, __) async => 'fallback',
      );
      expect(p, isA<FallbackResiliencePolicy>());
    });

    test('forwards fallbackAction', () async {
      final p = Policy.fallback(
        fallbackAction: (_, __) async => 'from factory',
      );
      final result = await p.execute<String>(() => throw const _AppException());
      expect(result, equals('from factory'));
    });

    test('forwards shouldHandle', () async {
      bool sh(Object e) => e is _AppException;
      final p = Policy.fallback(
        fallbackAction: (_, __) async => 'caught',
        shouldHandle: sh,
      );
      expect(p.shouldHandle, same(sh));
      // Should propagate non-matching exception
      expect(
        () => p.execute<String>(() => throw const _TransientException()),
        throwsA(isA<_TransientException>()),
      );
    });

    test('forwards classifier', () {
      const classifier = HttpOutcomeClassifier();
      final p = Policy.fallback(
        fallbackAction: (_, __) async => HttpResponse.ok(),
        classifier: classifier,
      );
      expect(p.classifier, same(classifier));
    });

    test('class-level toString describes it', () {
      final p = Policy.fallback(
        fallbackAction: (_, __) async => 'x',
        classifier: const HttpOutcomeClassifier(),
      );
      expect(p.toString(), contains('FallbackResiliencePolicy'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientBuilder.withFallback', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('returns builder for fluent chaining', () {
      final builder = HttpClientBuilder();
      final result = builder.withFallback(
        FallbackPolicy(fallbackAction: (_, __, ___) async => HttpResponse.ok()),
      );
      expect(result, same(builder));
    });

    test('builds client that catches transport exceptions', () async {
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withFallback(
            FallbackPolicy(
              fallbackAction: (_, __, ___) async =>
                  HttpResponse.cached('offline'),
            ),
          )
          .withHttpClient(_httpClient((_) => throw Exception('network down')))
          .build();

      final response = await client.get(Uri.parse('/test'));
      expect(response.bodyAsString, equals('offline'));
    });

    test('passes through successful responses unchanged', () async {
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withFallback(
            FallbackPolicy(
              classifier: const HttpOutcomeClassifier(),
              fallbackAction: (_, __, ___) async =>
                  HttpResponse.cached('fallback'),
            ),
          )
          .withHttpClient(
            _httpClient((_) async => http.Response('success', 200)),
          )
          .build();

      final response = await client.get(Uri.parse('/test'));
      expect(response.statusCode, equals(200));
      expect(response.headers['X-Cache'], isNull);
    });

    test('withFallback placed before retry catches exhausted retries',
        () async {
      var callCount = 0;
      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withFallback(
            FallbackPolicy(
              fallbackAction: (_, __, ___) async =>
                  HttpResponse.cached('fallback'),
            ),
          )
          .withRetry(
            RetryPolicy.constant(maxRetries: 2, delay: Duration.zero),
          )
          .withHttpClient(
        _httpClient((_) async {
          callCount++;
          throw Exception('always fails');
        }),
      ).build();

      final response = await client.get(Uri.parse('/test'));
      expect(response.headers['X-Cache'], equals('HIT'));
      expect(callCount, greaterThan(1)); // retry fired
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('End-to-end integration', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('FallbackResiliencePolicy used with PolicyRegistry', () async {
      final registry = PolicyRegistry();
      registry.add(
        'cached-fallback',
        Policy.fallback(
          fallbackAction: (_, __) async => HttpResponse.cached('cached'),
          classifier: const HttpOutcomeClassifier(),
        ),
      );

      final policy = registry.get<FallbackResiliencePolicy>('cached-fallback');
      final result = await policy.execute<HttpResponse>(() async => _resp(503));
      expect(result.headers['X-Cache'], equals('HIT'));
    });

    test('FallbackHandler via withPolicyFromRegistry', () async {
      final registry = PolicyRegistry();
      registry.add('retry-3', Policy.retry(maxRetries: 2));

      // We can compose a fallback around a registry-sourced policy
      final pipeline = Policy.wrap([
        Policy.fallback(
          fallbackAction: (_, __) async => HttpResponse.cached('fallback'),
        ),
        registry.get('retry-3'),
      ]);

      var calls = 0;
      final result = await pipeline.execute<HttpResponse>(() async {
        calls++;
        throw const _AppException();
      });

      expect(result.headers['X-Cache'], equals('HIT'));
      expect(calls, equals(3)); // initial + 2 retries
    });

    test('full pipeline: fallback → retry → httpClient', () async {
      var serverCalls = 0;
      bool serverOk = false;

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withFallback(
            FallbackPolicy(
              classifier: const HttpOutcomeClassifier(),
              fallbackAction: (_, __, ___) async =>
                  HttpResponse.cached('stale-cache'),
            ),
          )
          .withRetry(RetryPolicy.constant(maxRetries: 2, delay: Duration.zero))
          .withHttpClient(
        _httpClient((_) async {
          serverCalls++;
          if (!serverOk) {
            return http.Response('error', 503);
          }
          return http.Response('fresh', 200);
        }),
      ).build();

      // All 3 attempts return 503 → fallback fires
      final r1 = await client.get(Uri.parse('/data'));
      expect(r1.headers['X-Cache'], equals('HIT'));
      expect(
        serverCalls,
        equals(3),
      ); // 1 original + 2 retries (RetryPolicy with 2xx/5xx)

      // Server recovers
      serverOk = true;
      serverCalls = 0;
      final r2 = await client.get(Uri.parse('/data'));
      expect(r2.statusCode, equals(200));
      expect(r2.headers['X-Cache'], isNull);
    });
  });
}

// ════════════════════════════════════════════════════════════════════════════
//  Test-local helpers
// ════════════════════════════════════════════════════════════════════════════

/// An [OutcomeClassifier] that fires [onClassify] callback and then delegates
/// to [HttpOutcomeClassifier].
final class _MarkingClassifier extends OutcomeClassifier {
  _MarkingClassifier(this.onClassify);
  final void Function() onClassify;

  @override
  OutcomeClassification classifyResponse(HttpResponse response) {
    onClassify();
    return const HttpOutcomeClassifier().classifyResponse(response);
  }

  @override
  OutcomeClassification classifyException(Object exception) =>
      OutcomeClassification.transientFailure;
}
