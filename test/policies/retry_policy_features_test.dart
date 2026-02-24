// Tests for RetryPolicy features added in Phase 5:
//   - copyWith()
//   - respectRetryAfterHeader / maxRetryAfterDelay
//   - policy-level CancellationToken

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Builds a [ResilientHttpClient] backed by [inner] with the given [policy].
ResilientHttpClient _buildClient(
  http.Client inner,
  RetryPolicy policy,
) =>
    HttpClientBuilder()
        .withBaseUri(Uri.parse('https://test.example'))
        .withHttpClient(inner)
        .withRetry(policy)
        .build();

/// Client that returns [statusCode] + response `headers` on the first
/// [failTimes] calls, then succeeds with a 200.
http.Client _flakyClient(
  int failTimes, {
  int statusCode = 503,
  Map<String, String> responseHeaders = const {},
}) {
  var calls = 0;
  return http_testing.MockClient((_) async {
    calls++;
    if (calls <= failTimes) {
      return http.Response('retry-me', statusCode, headers: responseHeaders);
    }
    return http.Response('ok', 200);
  });
}

// ════════════════════════════════════════════════════════════════════════════
//  copyWith
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('RetryPolicy.copyWith', () {
    test('preserves all unspecified fields', () {
      final original = RetryPolicy.exponential(maxRetries: 3);
      final copy = original.copyWith(respectRetryAfterHeader: true);

      expect(copy.maxRetries, 3);
      expect(copy.respectRetryAfterHeader, isTrue);
      expect(copy.maxRetryAfterDelay, isNull);
      expect(copy.cancellationToken, isNull);
    });

    test('overrides maxRetries independently', () {
      final original = RetryPolicy.constant(maxRetries: 2);
      final copy = original.copyWith(maxRetries: 7);
      expect(copy.maxRetries, 7);
    });

    test('is non-mutating — original instance unchanged', () {
      final original = RetryPolicy.constant(maxRetries: 2);
      original.copyWith(maxRetries: 99, respectRetryAfterHeader: true);
      expect(original.maxRetries, 2);
      expect(original.respectRetryAfterHeader, isFalse);
    });

    test('can set maxRetryAfterDelay via copyWith', () {
      final policy = RetryPolicy.exponential(maxRetries: 3)
          .copyWith(maxRetryAfterDelay: const Duration(seconds: 10));
      expect(policy.maxRetryAfterDelay, const Duration(seconds: 10));
    });

    test('can attach a CancellationToken via copyWith', () {
      final token = CancellationToken();
      final policy = RetryPolicy.constant(maxRetries: 2)
          .copyWith(cancellationToken: token);
      expect(policy.cancellationToken, same(token));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Retry-After header
  // ──────────────────────────────────────────────────────────────────────────

  group('RetryPolicy — respectRetryAfterHeader', () {
    test('defaults to false', () {
      expect(
        RetryPolicy.constant(maxRetries: 1).respectRetryAfterHeader,
        isFalse,
      );
      expect(
        RetryPolicy.exponential(maxRetries: 1).respectRetryAfterHeader,
        isFalse,
      );
    });

    test('stored when set on an explicit RetryPolicy.custom', () {
      final policy = RetryPolicy.custom(
        maxRetries: 2,
        delayProvider: (_) => Duration.zero,
      ).copyWith(respectRetryAfterHeader: true);
      expect(policy.respectRetryAfterHeader, isTrue);
    });

    test('RetryHandler follows a positive Retry-After header', () async {
      // Retry-After: 1 would take 1 s; cap it to Duration.zero via
      // maxRetryAfterDelay to keep the test instant while still exercising
      // the Retry-After parsing and capping code path.
      final policy = RetryPolicy.constant(
        maxRetries: 1,
        delay: const Duration(
          seconds: 60,
        ), // would make test slow if NOT overridden
        shouldRetry: (r, _, __) => r?.statusCode == 503,
      ).copyWith(
        respectRetryAfterHeader: true,
        maxRetryAfterDelay: Duration.zero, // caps 1s to 0ms
      );

      final client = _buildClient(
        _flakyClient(1, responseHeaders: {'retry-after': '1'}),
        policy,
      );
      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
    });

    test('Retry-After: 0 (non-positive) falls back to computed delay',
        () async {
      // _parseRetryAfter returns null for 0; the parser treats non-positive
      // values as absent and falls back to the computed delay.
      // Use computed delay of zero so the test stays instant regardless.
      final policy = RetryPolicy.constant(
        maxRetries: 1,
        delay: Duration.zero,
        shouldRetry: (r, _, __) => r?.statusCode == 503,
      ).copyWith(respectRetryAfterHeader: true);

      final client = _buildClient(
        _flakyClient(1, responseHeaders: {'retry-after': '0'}),
        policy,
      );
      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
    });

    test('Retry-After larger than maxRetryAfterDelay is capped', () async {
      // Server says "wait 60 s" but cap is 0 ms → test stays instant.
      final policy = RetryPolicy.constant(
        maxRetries: 1,
        delay: const Duration(seconds: 60),
        shouldRetry: (r, _, __) => r?.statusCode == 429,
      ).copyWith(
        respectRetryAfterHeader: true,
        maxRetryAfterDelay: Duration.zero,
      );

      final client = _buildClient(
        _flakyClient(
          1,
          statusCode: 429,
          responseHeaders: {'retry-after': '60'},
        ),
        policy,
      );
      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
    });

    test('non-numeric Retry-After falls back to computed delay', () async {
      // HTTP-date format should not crash; computed delay (0 ms via copyWith) used.
      final policy = RetryPolicy.constant(
        maxRetries: 1,
        delay: Duration.zero,
        shouldRetry: (r, _, __) => r?.statusCode == 503,
      ).copyWith(respectRetryAfterHeader: true);

      final client = _buildClient(
        _flakyClient(
          1,
          responseHeaders: {'retry-after': 'Wed, 21 Oct 2015 07:28:00 GMT'},
        ),
        policy,
      );
      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
    });

    test('header ignored when respectRetryAfterHeader is false', () async {
      // Computed delay is 0 ms → succeeds quickly without using the header.
      final policy = RetryPolicy.constant(
        maxRetries: 1,
        delay: Duration.zero,
        shouldRetry: (r, _, __) => r?.statusCode == 503,
      );
      expect(policy.respectRetryAfterHeader, isFalse);

      final client = _buildClient(
        _flakyClient(1, responseHeaders: {'retry-after': '0'}),
        policy,
      );
      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Policy-level CancellationToken
  // ──────────────────────────────────────────────────────────────────────────

  group('RetryPolicy — policy-level CancellationToken', () {
    test('is null by default', () {
      expect(RetryPolicy.constant(maxRetries: 3).cancellationToken, isNull);
    });

    test('stored after copyWith', () {
      final token = CancellationToken();
      final policy = RetryPolicy.constant(maxRetries: 3)
          .copyWith(cancellationToken: token);
      expect(policy.cancellationToken, same(token));
    });

    test('aborts immediately when token is already cancelled', () {
      final token = CancellationToken()..cancel('shutdown');
      final policy = RetryPolicy.constant(maxRetries: 3)
          .copyWith(cancellationToken: token);

      final client = _buildClient(
        http_testing.MockClient((_) async => http.Response('ok', 200)),
        policy,
      );

      expect(
        client.get(Uri.parse('/resource')),
        throwsA(isA<CancellationException>()),
      );
    });

    test('aborts retry loop when token is cancelled between attempts',
        () async {
      final token = CancellationToken();
      var calls = 0;

      final flakyHttp = http_testing.MockClient((_) async {
        calls++;
        if (calls == 1) {
          token.cancel('shutdown mid-flight');
          return http.Response('error', 503);
        }
        return http.Response('ok', 200);
      });

      final policy = RetryPolicy.constant(
        maxRetries: 3,
        delay: Duration.zero,
        shouldRetry: (r, _, __) => r?.statusCode == 503,
      ).copyWith(cancellationToken: token);

      await expectLater(
        _buildClient(flakyHttp, policy).get(Uri.parse('/resource')),
        throwsA(isA<CancellationException>()),
      );
      expect(calls, 1); // cancelled before attempt 2
    });
  });
}
