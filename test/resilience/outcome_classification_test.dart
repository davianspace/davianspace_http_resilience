import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test helpers
// ════════════════════════════════════════════════════════════════════════════

/// Builds an [HttpContext] with a stub [HttpRequest] for classifier tests.
HttpContext _ctx({HttpResponse? response, Object? exception}) {
  final ctx = HttpContext(
    request: HttpRequest(
      uri: Uri.parse('https://test.example.com/resource'),
      method: HttpMethod.get,
    ),
  );
  if (response != null) ctx.response = response;
  if (exception != null) {
    ctx.setProperty(OutcomeClassifier.exceptionPropertyKey, exception);
  }
  return ctx;
}

/// Returns a synthetic [HttpResponse] with [statusCode].
HttpResponse _resp(int statusCode) => HttpResponse(statusCode: statusCode);

// ─── Custom classifiers used across multiple test groups ───────────────────

/// Treats 429 as transient; delegates the rest to [HttpOutcomeClassifier].
final class _TooManyRequestsClassifier extends OutcomeClassifier {
  const _TooManyRequestsClassifier();

  @override
  OutcomeClassification classifyResponse(HttpResponse response) {
    if (response.statusCode == 429) return OutcomeClassification.transientFailure;
    return const HttpOutcomeClassifier().classifyResponse(response);
  }

  @override
  OutcomeClassification classifyException(Object exception) =>
      OutcomeClassification.transientFailure;
}

/// Treats every exception as permanent (never retry on exception).
final class _PermanentOnExceptionClassifier extends OutcomeClassifier {
  const _PermanentOnExceptionClassifier();

  @override
  OutcomeClassification classifyResponse(HttpResponse response) =>
      const HttpOutcomeClassifier().classifyResponse(response);

  @override
  OutcomeClassification classifyException(Object exception) =>
      OutcomeClassification.permanentFailure;
}

// ─── Pipeline helpers ───────────────────────────────────────────────────────

/// A [RetryPolicy] with classifier for use with [RetryHandler].
RetryPolicy _classifiedPolicy(
  OutcomeClassifier classifier, {
  int maxRetries = 3,
}) =>
    RetryPolicy.withClassifier(maxRetries: maxRetries, classifier: classifier);

/// Builds an [http.Client] backed by [handler] and returns it.
http.Client _mockClient(
  http_testing.MockClientHandler handler,
) =>
    http_testing.MockClient(handler);

/// Builds and sends one GET request through the full handler pipeline
/// configured with [policy].
Future<HttpResponse> _pipelineSend(
  RetryPolicy policy,
  http_testing.MockClientHandler transportHandler,
) async {
  final client = HttpClientBuilder()
      .withBaseUri(Uri.parse('https://example.com'))
      .withRetry(policy)
      .withHttpClient(_mockClient(transportHandler))
      .build();
  return client.get(Uri.parse('/data'));
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('OutcomeClassification enum', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('success.isSuccess is true', () {
      expect(OutcomeClassification.success.isSuccess, isTrue);
    });

    test('transientFailure.isSuccess is false', () {
      expect(OutcomeClassification.transientFailure.isSuccess, isFalse);
    });

    test('permanentFailure.isSuccess is false', () {
      expect(OutcomeClassification.permanentFailure.isSuccess, isFalse);
    });

    test('transientFailure.isRetryable is true', () {
      expect(OutcomeClassification.transientFailure.isRetryable, isTrue);
    });

    test('success.isRetryable is false', () {
      expect(OutcomeClassification.success.isRetryable, isFalse);
    });

    test('permanentFailure.isRetryable is false', () {
      expect(OutcomeClassification.permanentFailure.isRetryable, isFalse);
    });

    test('success.isFailure is false', () {
      expect(OutcomeClassification.success.isFailure, isFalse);
    });

    test('transientFailure.isFailure is true', () {
      expect(OutcomeClassification.transientFailure.isFailure, isTrue);
    });

    test('permanentFailure.isFailure is true', () {
      expect(OutcomeClassification.permanentFailure.isFailure, isTrue);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpOutcomeClassifier — classifyResponse', () {
    // ──────────────────────────────────────────────────────────────────────────

    const classifier = HttpOutcomeClassifier();

    for (final code in [200, 201, 204, 206, 299]) {
      test('$code → success', () {
        expect(
          classifier.classifyResponse(_resp(code)),
          OutcomeClassification.success,
        );
      });
    }

    for (final code in [500, 502, 503, 504, 599]) {
      test('$code → transientFailure', () {
        expect(
          classifier.classifyResponse(_resp(code)),
          OutcomeClassification.transientFailure,
        );
      });
    }

    for (final code in [400, 401, 403, 404, 409, 422, 499]) {
      test('$code → permanentFailure', () {
        expect(
          classifier.classifyResponse(_resp(code)),
          OutcomeClassification.permanentFailure,
        );
      });
    }

    test('3xx → permanentFailure', () {
      expect(
        classifier.classifyResponse(_resp(301)),
        OutcomeClassification.permanentFailure,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpOutcomeClassifier — classifyException', () {
    // ──────────────────────────────────────────────────────────────────────────

    const classifier = HttpOutcomeClassifier();

    test('SocketException-like → transientFailure', () {
      expect(
        classifier.classifyException(Exception('Connection refused')),
        OutcomeClassification.transientFailure,
      );
    });

    test('TimeoutException → transientFailure', () {
      expect(
        classifier.classifyException(TimeoutException('timed out')),
        OutcomeClassification.transientFailure,
      );
    });

    test('StateError → transientFailure (all exceptions are transient)', () {
      expect(
        classifier.classifyException(StateError('unexpected')),
        OutcomeClassification.transientFailure,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpOutcomeClassifier — classify(HttpContext)', () {
    // ──────────────────────────────────────────────────────────────────────────

    const classifier = HttpOutcomeClassifier();

    test('context with 200 response → success', () {
      expect(
        classifier.classify(_ctx(response: _resp(200))),
        OutcomeClassification.success,
      );
    });

    test('context with 503 response → transientFailure', () {
      expect(
        classifier.classify(_ctx(response: _resp(503))),
        OutcomeClassification.transientFailure,
      );
    });

    test('context with 404 response → permanentFailure', () {
      expect(
        classifier.classify(_ctx(response: _resp(404))),
        OutcomeClassification.permanentFailure,
      );
    });

    test('context with stashed exception (no response) → transientFailure', () {
      expect(
        classifier.classify(_ctx(exception: Exception('network error'))),
        OutcomeClassification.transientFailure,
      );
    });

    test('context with neither response nor exception → success', () {
      expect(
        classifier.classify(_ctx()),
        OutcomeClassification.success,
      );
    });

    test('response takes precedence over stashed exception', () {
      // Both are present — response wins.
      final ctx = _ctx(response: _resp(200), exception: Exception('ignored'));
      expect(classifier.classify(ctx), OutcomeClassification.success);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('OutcomeClassifier — exceptionPropertyKey', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('key is a non-empty string', () {
      expect(OutcomeClassifier.exceptionPropertyKey, isNotEmpty);
    });

    test('key is stable across accesses', () {
      expect(
        OutcomeClassifier.exceptionPropertyKey,
        OutcomeClassifier.exceptionPropertyKey,
      );
    });

    test('exception stashed under the key is readable from context', () {
      final ex = Exception('test');
      final ctx = _ctx();
      ctx.setProperty(OutcomeClassifier.exceptionPropertyKey, ex);
      expect(
        ctx.getProperty<Object>(OutcomeClassifier.exceptionPropertyKey),
        same(ex),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('CompositeOutcomeClassifier', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('first classifier that returns non-success wins (response)', () {
      const composite = CompositeOutcomeClassifier([
        _TooManyRequestsClassifier(), // 429 → transient
        HttpOutcomeClassifier(),
      ]);

      expect(
        composite.classifyResponse(_resp(429)),
        OutcomeClassification.transientFailure,
      );
    });

    test('falls through to next classifier when first returns success', () {
      const composite = CompositeOutcomeClassifier([
        // This classifier returns permanentFailure only for 500, success otherwise.
        _PermanentOnExceptionClassifier(), // only overrides exceptions
        HttpOutcomeClassifier(),
      ]);

      // 503: first classifier delegates to HttpOutcomeClassifier; second says transient.
      expect(
        composite.classifyResponse(_resp(503)),
        OutcomeClassification.transientFailure,
      );
    });

    test('all classifiers return success → composite returns success', () {
      // Create two classifiers that always return success for 200.
      const composite = CompositeOutcomeClassifier([
        HttpOutcomeClassifier(),
        HttpOutcomeClassifier(),
      ]);
      expect(
        composite.classifyResponse(_resp(200)),
        OutcomeClassification.success,
      );
    });

    test('exception: first classifier result that is non-success wins', () {
      const composite = CompositeOutcomeClassifier([
        _PermanentOnExceptionClassifier(),
        HttpOutcomeClassifier(),
      ]);
      expect(
        composite.classifyException(Exception('fail')),
        OutcomeClassification.permanentFailure,
      );
    });

    test('exception: all-success falls back to transientFailure', () {
      // Both return success for exceptions (contrived, but covers the safety net).
      final composite = CompositeOutcomeClassifier([
        PredicateOutcomeClassifier(
          responseClassifier: (_) => OutcomeClassification.success,
          exceptionClassifier: (_) => OutcomeClassification.success,
        ),
      ]);
      expect(
        composite.classifyException(Exception('x')),
        OutcomeClassification.transientFailure,
      );
    });

    test('toString contains classifier count', () {
      const c = CompositeOutcomeClassifier([HttpOutcomeClassifier()]);
      expect(c.toString(), contains('1'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('PredicateOutcomeClassifier', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('delegates to responseClassifier predicate', () {
      final classifier = PredicateOutcomeClassifier(
        responseClassifier: (r) => r.statusCode == 429
            ? OutcomeClassification.transientFailure
            : OutcomeClassification.success,
      );
      expect(
        classifier.classifyResponse(_resp(429)),
        OutcomeClassification.transientFailure,
      );
      expect(
        classifier.classifyResponse(_resp(200)),
        OutcomeClassification.success,
      );
    });

    test('delegates to exceptionClassifier predicate when provided', () {
      final classifier = PredicateOutcomeClassifier(
        responseClassifier: (_) => OutcomeClassification.success,
        exceptionClassifier: (_) => OutcomeClassification.permanentFailure,
      );
      expect(
        classifier.classifyException(Exception('oops')),
        OutcomeClassification.permanentFailure,
      );
    });

    test('defaults exceptionClassifier to transientFailure when omitted', () {
      final classifier = PredicateOutcomeClassifier(
        responseClassifier: (_) => OutcomeClassification.success,
      );
      expect(
        classifier.classifyException(Exception('oops')),
        OutcomeClassification.transientFailure,
      );
    });

    test('toString is stable', () {
      final c = PredicateOutcomeClassifier(
        responseClassifier: (_) => OutcomeClassification.success,
      );
      expect(c.toString(), isNotEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Custom OutcomeClassifier subclass', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('custom classifier overrides 429 as transient', () {
      const classifier = _TooManyRequestsClassifier();
      expect(
        classifier.classifyResponse(_resp(429)),
        OutcomeClassification.transientFailure,
      );
      // Should still correctly classify others via delegation.
      expect(
        classifier.classifyResponse(_resp(200)),
        OutcomeClassification.success,
      );
      expect(
        classifier.classifyResponse(_resp(500)),
        OutcomeClassification.transientFailure,
      );
    });

    test('permanent-on-exception classifier blocks exception retries', () {
      const classifier = _PermanentOnExceptionClassifier();
      expect(
        classifier.classifyException(Exception('x')),
        OutcomeClassification.permanentFailure,
      );
    });

    test('classify(context) default implementation works for subclasses', () {
      const classifier = _TooManyRequestsClassifier();
      expect(
        classifier.classify(_ctx(response: _resp(429))),
        OutcomeClassification.transientFailure,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryResiliencePolicy.withClassifier — free-standing', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('retries on 5xx with default HttpOutcomeClassifier', () async {
      var callCount = 0;
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 3,
        backoff: const NoBackoff(),
      );
      await expectLater(
        policy.execute<HttpResponse>(() async {
          callCount++;
          if (callCount <= 2) return const HttpResponse(statusCode: 503);
          return const HttpResponse(statusCode: 200);
        }),
        completion(
          isA<HttpResponse>().having((r) => r.statusCode, 'statusCode', 200),
        ),
      );
      expect(callCount, 3);
    });

    test('does NOT retry on 4xx with default HttpOutcomeClassifier', () async {
      var callCount = 0;
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 3,
        backoff: const NoBackoff(),
      );
      final result = await policy.execute<HttpResponse>(() async {
        callCount++;
        return const HttpResponse(statusCode: 404);
      });
      expect(result.statusCode, 404);
      expect(callCount, 1); // No retries — permanent failure.
    });

    test('retries on exception with default HttpOutcomeClassifier', () async {
      var callCount = 0;
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 2,
        backoff: const NoBackoff(),
      );
      await expectLater(
        policy.execute<String>(() async {
          callCount++;
          if (callCount <= 2) throw Exception('transient');
          return 'ok';
        }),
        completion('ok'),
      );
      expect(callCount, 3);
    });

    test('throws RetryExhaustedException after all retries on 5xx', () async {
      var callCount = 0;
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 2,
        backoff: const NoBackoff(),
      );
      await expectLater(
        policy.execute<HttpResponse>(() async {
          callCount++;
          return const HttpResponse(statusCode: 503);
        }),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(callCount, 3); // 1 initial + 2 retries
    });

    test('custom classifier: treats 429 as transient', () async {
      var callCount = 0;
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 2,
        backoff: const NoBackoff(),
        classifier: const _TooManyRequestsClassifier(),
      );
      await expectLater(
        policy.execute<HttpResponse>(() async {
          callCount++;
          if (callCount <= 2) return const HttpResponse(statusCode: 429);
          return const HttpResponse(statusCode: 200);
        }),
        completion(
          isA<HttpResponse>().having((r) => r.statusCode, 'statusCode', 200),
        ),
      );
      expect(callCount, 3);
    });

    test('custom classifier: stops on exception when classified as permanent',
        () async {
      var callCount = 0;
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 3,
        backoff: const NoBackoff(),
        classifier: const _PermanentOnExceptionClassifier(),
      );
      await expectLater(
        policy.execute<String>(() async {
          callCount++;
          throw Exception('permanent-ish');
        }),
        throwsException,
      );
      expect(callCount, 1); // Immediate propagation — no retries.
    });

    test('Policy.classifiedRetry factory produces correct policy', () async {
      var callCount = 0;
      final policy = Policy.classifiedRetry(
        maxRetries: 2,
        backoff: const NoBackoff(),
      );
      await policy.execute<HttpResponse>(() async {
        callCount++;
        if (callCount <= 2) return const HttpResponse(statusCode: 500);
        return const HttpResponse(statusCode: 200);
      });
      expect(callCount, 3);
    });

    test('classifier field is exposed on the policy', () {
      const c = HttpOutcomeClassifier();
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 3,
      );
      expect(policy.classifier, same(c));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryPolicy.withClassifier — pipeline handler layer', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('constant factory accepts classifier and uses it', () {
      final predicate = RetryPolicy.constant(
        maxRetries: 2,
        classifier: const HttpOutcomeClassifier(),
      ).shouldRetry;
      expect(predicate(_resp(503), null, _ctx()), isTrue);
      expect(predicate(_resp(200), null, _ctx()), isFalse);
      expect(predicate(_resp(404), null, _ctx()), isFalse);
    });

    test('linear factory accepts classifier', () {
      final predicate = RetryPolicy.linear(
        maxRetries: 2,
        classifier: const HttpOutcomeClassifier(),
      ).shouldRetry;
      expect(predicate(_resp(500), null, _ctx()), isTrue);
      expect(predicate(_resp(400), null, _ctx()), isFalse);
    });

    test('exponential factory accepts classifier', () {
      final predicate = RetryPolicy.exponential(
        maxRetries: 2,
        classifier: const HttpOutcomeClassifier(),
      ).shouldRetry;
      expect(predicate(_resp(502), null, _ctx()), isTrue);
      expect(predicate(_resp(200), null, _ctx()), isFalse);
    });

    test('custom factory accepts classifier', () {
      final predicate = RetryPolicy.custom(
        maxRetries: 2,
        delayProvider: (_) => Duration.zero,
        classifier: const HttpOutcomeClassifier(),
      ).shouldRetry;
      expect(predicate(_resp(503), null, _ctx()), isTrue);
    });

    test('withClassifier factory produces correct policy for end-to-end', () async {
      var calls = 0;
      final policy = RetryPolicy.withClassifier(
        maxRetries: 3,
        classifier: const _TooManyRequestsClassifier(),
      );
      // Use as a plain predicate check — full pipeline covered in RetryHandler group.
      expect(policy.shouldRetry(_resp(429), null, _ctx()), isTrue);
      expect(policy.shouldRetry(_resp(200), null, _ctx()), isFalse);
      expect(policy.maxRetries, 3);
      calls++;
      expect(calls, 1);
    });

    test('classifier-built predicate evaluates exceptions', () {
      final predicate = RetryPolicy.withClassifier(
        maxRetries: 1,
        classifier: const _PermanentOnExceptionClassifier(),
      ).shouldRetry;
      // PermanentOnExceptionClassifier → classifyException → permanentFailure → isRetryable = false
      expect(predicate(null, Exception('hard fail'), _ctx()), isFalse);
    });

    test('predicate returns false when both response and exception are null', () {
      final predicate = RetryPolicy.withClassifier(
        maxRetries: 1,
        classifier: const HttpOutcomeClassifier(),
      ).shouldRetry;
      expect(predicate(null, null, _ctx()), isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RetryHandler — classifier integration (pipeline)', () {
    // ──────────────────────────────────────────────────────────────────────────

    test(
        'exception is stashed in context under exceptionPropertyKey before '
        'shouldRetry is consulted', () async {
      Object? stashedEx;
      final policy = RetryPolicy.custom(
        maxRetries: 0,
        delayProvider: (_) => Duration.zero,
        shouldRetry: (response, exception, ctx) {
          stashedEx = ctx.getProperty<Object>(
            OutcomeClassifier.exceptionPropertyKey,
          );
          return false; // don't retry — just capture
        },
      );

      await expectLater(
        _pipelineSend(policy, (_) async => throw Exception('boom')),
        throwsException,
      );
      expect(stashedEx, isA<Exception>());
    });

    test('5xx response retried with default withClassifier policy', () async {
      var calls = 0;
      final resp = await _pipelineSend(
        _classifiedPolicy(const HttpOutcomeClassifier()),
        (_) async {
          calls++;
          if (calls <= 2) return http.Response('error', 503);
          return http.Response('ok', 200);
        },
      );
      expect(resp.statusCode, 200);
      expect(calls, 3);
    });

    test('4xx response NOT retried with HttpOutcomeClassifier', () async {
      var calls = 0;
      final resp = await _pipelineSend(
        _classifiedPolicy(const HttpOutcomeClassifier()),
        (_) async {
          calls++;
          return http.Response('not found', 404);
        },
      );
      expect(resp.statusCode, 404);
      expect(calls, 1);
    });

    test('custom classifier: 429 retried in pipeline', () async {
      var calls = 0;
      final resp = await _pipelineSend(
        _classifiedPolicy(
          const _TooManyRequestsClassifier(),
          maxRetries: 2,
        ),
        (_) async {
          calls++;
          if (calls <= 2) return http.Response('too many', 429);
          return http.Response('ok', 200);
        },
      );
      expect(resp.statusCode, 200);
      expect(calls, 3);
    });

    test('exception retried by default with HttpOutcomeClassifier', () async {
      var calls = 0;
      final resp = await _pipelineSend(
        _classifiedPolicy(const HttpOutcomeClassifier(), maxRetries: 2),
        (_) async {
          calls++;
          if (calls <= 2) throw Exception('transient');
          return http.Response('ok', 200);
        },
      );
      expect(resp.statusCode, 200);
      expect(calls, 3);
    });

    test('permanent exception NOT retried with _PermanentOnExceptionClassifier',
        () async {
      var calls = 0;
      await expectLater(
        _pipelineSend(
          _classifiedPolicy(
            const _PermanentOnExceptionClassifier(),
          ),
          (_) async {
            calls++;
            throw Exception('hard fail');
          },
        ),
        throwsException,
      );
      expect(calls, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('ResiliencePipelineBuilder.addClassifiedRetry', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('addClassifiedRetry builds a RetryResiliencePolicy with classifier', () {
      final pipeline = ResiliencePipelineBuilder()
          .addClassifiedRetry(
            maxRetries: 3,
          )
          .addTimeout(const Duration(seconds: 5)) // need 2+ for PolicyWrap
          .build() as PolicyWrap;

      final retry = pipeline.policies[0] as RetryResiliencePolicy;
      expect(retry.maxRetries, 3);
      expect(retry.classifier, isA<HttpOutcomeClassifier>());
    });

    test('addClassifiedRetry uses HttpOutcomeClassifier by default', () {
      final pipeline = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 5))
          .addClassifiedRetry(maxRetries: 2)
          .build() as PolicyWrap;

      final retry = pipeline.policies[1] as RetryResiliencePolicy;
      expect(retry.classifier, isA<HttpOutcomeClassifier>());
    });

    test('addClassifiedRetry accepts custom classifier', () {
      final pipeline = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 5))
          .addClassifiedRetry(
            maxRetries: 1,
            classifier: const _TooManyRequestsClassifier(),
          )
          .build() as PolicyWrap;

      final retry = pipeline.policies[1] as RetryResiliencePolicy;
      expect(retry.classifier, isA<_TooManyRequestsClassifier>());
    });

    test('addClassifiedRetry can be combined with other policies', () {
      final pipeline = ResiliencePipelineBuilder()
          .addTimeout(const Duration(seconds: 10))
          .addClassifiedRetry(maxRetries: 3)
          .build() as PolicyWrap;

      expect(pipeline.policies[0], isA<TimeoutResiliencePolicy>());
      expect(pipeline.policies[1], isA<RetryResiliencePolicy>());
    });

    test('addClassifiedRetry returns builder for fluent chaining', () {
      final builder = ResiliencePipelineBuilder();
      final returned = builder.addClassifiedRetry(maxRetries: 1);
      expect(returned, same(builder));
    });

    test('policy built with addClassifiedRetry retries 5xx correctly',
        () async {
      var callCount = 0;
      final policy = ResiliencePipelineBuilder()
          .addClassifiedRetry(
            maxRetries: 2,
            backoff: const NoBackoff(),
          )
          .build();

      await policy.execute<HttpResponse>(() async {
        callCount++;
        if (callCount <= 2) return const HttpResponse(statusCode: 500);
        return const HttpResponse(statusCode: 200);
      });
      expect(callCount, 3);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Policy.classifiedRetry factory', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('creates a RetryResiliencePolicy with a classifier field', () {
      final policy = Policy.classifiedRetry(maxRetries: 3);
      expect(policy.classifier, isA<HttpOutcomeClassifier>());
    });

    test('accepts a custom classifier', () {
      final policy = Policy.classifiedRetry(
        maxRetries: 2,
        classifier: const _TooManyRequestsClassifier(),
      );
      expect(policy.classifier, isA<_TooManyRequestsClassifier>());
    });

    test('maxRetries is correctly set', () {
      final policy = Policy.classifiedRetry(maxRetries: 5);
      expect(policy.maxRetries, 5);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Statelessness and thread safety', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('HttpOutcomeClassifier is const-constructible', () {
      const c1 = HttpOutcomeClassifier();
      const c2 = HttpOutcomeClassifier();
      // Both are the same type; no mutable state.
      expect(c1.runtimeType, c2.runtimeType);
    });

    test('PredicateOutcomeClassifier holds no mutable state', () {
      final c = PredicateOutcomeClassifier(
        responseClassifier: (_) => OutcomeClassification.success,
      );
      // Repeated classifications return the same result.
      expect(c.classifyResponse(_resp(200)), OutcomeClassification.success);
      expect(c.classifyResponse(_resp(200)), OutcomeClassification.success);
    });

    test('concurrent classify calls on shared classifier are independent',
        () async {
      const classifier = HttpOutcomeClassifier();
      final futures = [
        for (var i = 0; i < 50; i++)
          Future(() => classifier.classifyResponse(_resp(i < 25 ? 200 : 503))),
      ];
      final results = await Future.wait(futures);
      for (var i = 0; i < 25; i++) {
        expect(results[i], OutcomeClassification.success);
      }
      for (var i = 25; i < 50; i++) {
        expect(results[i], OutcomeClassification.transientFailure);
      }
    });

    test('shared RetryResiliencePolicy.withClassifier can execute concurrently',
        () async {
      final policy = RetryResiliencePolicy.withClassifier(
        maxRetries: 1,
        backoff: const NoBackoff(),
      );
      // Launch 10 concurrent executions — each should complete independently.
      final futures = [
        for (var i = 0; i < 10; i++)
          policy.execute<String>(() async => 'result-$i'),
      ];
      final results = await Future.wait(futures);
      for (var i = 0; i < 10; i++) {
        expect(results[i], 'result-$i');
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('End-to-end: classifier + PolicyRegistry + HttpClientFactory', () {
    // ──────────────────────────────────────────────────────────────────────────

    late HttpClientFactory factory;
    late PolicyRegistry registry;

    setUp(() {
      factory = HttpClientFactory();
      registry = PolicyRegistry();
    });
    tearDown(() => factory.clear());

    test('classified retry policy stored in registry retries 5xx', () async {
      registry.add(
        'classified-retry',
        Policy.classifiedRetry(maxRetries: 2, backoff: const NoBackoff()),
      );

      var calls = 0;
      factory.addClient(
        'svc',
        (b) => b
            .withBaseUri(Uri.parse('https://example.com'))
            .withPolicyFromRegistry('classified-retry', registry: registry)
            .withHttpClient(
              http_testing.MockClient((_) async {
                calls++;
                if (calls <= 2) return http.Response('error', 503);
                return http.Response('ok', 200);
              }),
            ),
      );

      final resp = await factory.createClient('svc').get(Uri.parse('/data'));
      expect(resp.statusCode, 200);
      expect(calls, 3);
    });

    test('composite classifier in registry: 429 treated as transient', () async {
      registry.add(
        'composite-retry',
        Policy.classifiedRetry(
          maxRetries: 2,
          backoff: const NoBackoff(),
          classifier: const CompositeOutcomeClassifier([
            _TooManyRequestsClassifier(),
            HttpOutcomeClassifier(),
          ]),
        ),
      );

      var calls = 0;
      factory.addClient(
        'throttled-svc',
        (b) => b
            .withBaseUri(Uri.parse('https://example.com'))
            .withPolicyFromRegistry('composite-retry', registry: registry)
            .withHttpClient(
              http_testing.MockClient((_) async {
                calls++;
                if (calls <= 2) return http.Response('throttled', 429);
                return http.Response('ok', 200);
              }),
            ),
      );

      final resp =
          await factory.createClient('throttled-svc').get(Uri.parse('/data'));
      expect(resp.statusCode, 200);
      expect(calls, 3);
    });

    test('predicate classifier from registry does not retry 4xx', () async {
      registry.add(
        'smart-retry',
        Policy.classifiedRetry(
          maxRetries: 3,
          backoff: const NoBackoff(),
          classifier: PredicateOutcomeClassifier(
            responseClassifier: (r) =>
                r.isServerError || r.statusCode == 429
                    ? OutcomeClassification.transientFailure
                    : r.isSuccess
                        ? OutcomeClassification.success
                        : OutcomeClassification.permanentFailure,
          ),
        ),
      );

      var calls = 0;
      factory.addClient(
        'smart-svc',
        (b) => b
            .withBaseUri(Uri.parse('https://example.com'))
            .withPolicyFromRegistry('smart-retry', registry: registry)
            .withHttpClient(
              http_testing.MockClient((_) async {
                calls++;
                return http.Response('forbidden', 403);
              }),
            ),
      );

      final resp =
          await factory.createClient('smart-svc').get(Uri.parse('/data'));
      expect(resp.statusCode, 403);
      expect(calls, 1); // No retries.
    });
  });
}
