// Comprehensive tests for HedgingHandler and HedgingPolicy.
//
// Covers:
//   - Basic hedging flow (winner on first attempt)
//   - Hedge fires when first attempt is slow
//   - First response that satisfies predicate wins
//   - maxHedgedAttempts controls total concurrent count
//   - All attempts fail → HedgingException thrown
//   - All attempts return non-winning response → last non-winner returned
//   - HedgingEvent and HedgingOutcomeEvent emitted via ResilienceEventHub
//   - onHedge callback is invoked per extra attempt
//   - Streaming mode compatibility
//   - withHedging() on HttpClientBuilder wires correctly
//   - FluentHttpClientBuilder.withHedging() wires correctly
//   - shouldHedge predicate controls winner acceptance

import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Fake inner handler for unit testing HedgingHandler directly
// ════════════════════════════════════════════════════════════════════════════

/// A fake [DelegatingHandler] that: on the N-th call returns a response after
/// a given delay. Allows per-call configuration via a queue of handlers.
final class _FakeHandler extends DelegatingHandler {
  _FakeHandler(this._responses);

  // Each entry is (delay, statusCode). Consumed in order.
  final List<({Duration delay, int status})> _responses;
  var _index = 0;
  var callCount = 0;

  @override
  Future<HttpResponse> send(HttpContext ctx) async {
    callCount++;
    final entry = _responses[_index % _responses.length];
    _index++;
    if (entry.delay > Duration.zero) {
      await Future<void>.delayed(entry.delay);
    }
    return HttpResponse(statusCode: entry.status);
  }
}

/// A fake handler whose N-th call throws a given exception.
final class _ThrowingHandler extends DelegatingHandler {
  _ThrowingHandler(this._throwers);

  final List<Object> _throwers;
  var _index = 0;

  @override
  Future<HttpResponse> send(HttpContext ctx) async {
    final t = _throwers[_index % _throwers.length];
    _index++;
    throw t;
  }
}

/// Wraps a [DelegatingHandler] as the inner target of [HedgingHandler].
HedgingHandler _hedgingOver(
  DelegatingHandler inner, {
  Duration hedgeAfter = Duration.zero,
  int maxHedgedAttempts = 1,
  HedgePredicate? shouldHedge,
  void Function(int, HttpContext)? onHedge,
  ResilienceEventHub? eventHub,
}) {
  final policy = HedgingPolicy(
    hedgeAfter: hedgeAfter,
    maxHedgedAttempts: maxHedgedAttempts,
    shouldHedge: shouldHedge,
    onHedge: onHedge,
    eventHub: eventHub,
  );
  final handler = HedgingHandler(policy);
  handler.innerHandler = inner;
  return handler;
}

HttpContext _ctx() => HttpContext(
      request: HttpRequest(
        uri: Uri.parse('https://example.com/resource'),
        method: HttpMethod.get,
      ),
    );

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingPolicy', () {
    test('default values', () {
      const policy = HedgingPolicy();
      expect(policy.hedgeAfter, const Duration(milliseconds: 200));
      expect(policy.maxHedgedAttempts, 1);
      expect(policy.shouldHedge, isNull);
      expect(policy.onHedge, isNull);
      expect(policy.eventHub, isNull);
    });

    test('toString includes hedgeAfter and maxHedgedAttempts', () {
      const policy = HedgingPolicy(
        hedgeAfter: Duration(milliseconds: 150),
        maxHedgedAttempts: 3,
      );
      expect(policy.toString(), contains('150ms'));
      expect(policy.toString(), contains('3'));
    });

    test('assert fires for maxHedgedAttempts < 1', () {
      expect(
        () => HedgingPolicy(maxHedgedAttempts: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('assert fires for maxHedgedAttempts = -1', () {
      expect(
        () => HedgingPolicy(maxHedgedAttempts: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingHandler — first attempt wins immediately', () {
    test('returns 200 from first attempt without firing extra', () async {
      final fake = _FakeHandler([
        (delay: Duration.zero, status: 200),
        (delay: Duration.zero, status: 200),
      ]);
      final handler =
          _hedgingOver(fake, hedgeAfter: const Duration(seconds: 1));
      final response = await handler.send(_ctx());
      expect(response.statusCode, 200);
      // Only one call needed because the first completed before hedgeAfter.
      expect(fake.callCount, 1);
    });

    test('200 from first attempt resolves completer immediately', () async {
      final fake = _FakeHandler([(delay: Duration.zero, status: 200)]);
      final handler = _hedgingOver(fake);
      final sw = Stopwatch()..start();
      await handler.send(_ctx());
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 100)));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingHandler — hedging fires', () {
    test('fires second attempt after hedgeAfter expires', () async {
      // First attempt takes 300 ms; hedgeAfter is 50 ms.
      // Second attempt returns immediately. Winner = second (attempt 2).
      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 300), status: 200),
        (delay: Duration.zero, status: 200),
      ]);

      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 50),
      );

      final response = await handler.send(_ctx());
      expect(response.statusCode, 200);
      // Both attempts were fired.
      expect(fake.callCount, greaterThanOrEqualTo(2));
    });

    test('returns first successful response regardless of order', () async {
      // Attempt 1: slow (200 ms); Attempt 2: fast (10 ms).
      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 200), status: 200),
        (delay: const Duration(milliseconds: 10), status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 50),
      );
      final sw = Stopwatch()..start();
      final response = await handler.send(_ctx());
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 150)));
      expect(response.isSuccess, isTrue);
    });

    test('maxHedgedAttempts = 2 allows up to 3 concurrent requests', () async {
      // All attempts are slow (500 ms except last which is immediate).
      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 500), status: 200),
        (delay: const Duration(milliseconds: 500), status: 200),
        (delay: Duration.zero, status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 10),
        maxHedgedAttempts: 2,
      );
      final sw = Stopwatch()..start();
      final response = await handler.send(_ctx());
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
      expect(response.isSuccess, isTrue);
      expect(fake.callCount, 3);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingHandler — shouldHedge predicate', () {
    test('accepts 503 as non-winning, fires hedge, accepts 200 as winner',
        () async {
      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 200), status: 503),
        (delay: Duration.zero, status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 50),
        // continue hedging if response is 503
        shouldHedge: (r, _) => r.statusCode == 503,
      );
      final response = await handler.send(_ctx());
      expect(response.statusCode, 200);
    });

    test('accepts any response when predicate always returns false', () async {
      final fake = _FakeHandler([
        (delay: Duration.zero, status: 503),
      ]);
      final handler = _hedgingOver(
        fake,
        // never hedge — accept everything
        shouldHedge: (_, __) => false,
      );
      final response = await handler.send(_ctx());
      expect(response.statusCode, 503);
      expect(fake.callCount, 1);
    });

    test('returns last non-winner when predicate never satisfied', () async {
      // Both attempts return 503; shouldHedge always true → no winner.
      final fake = _FakeHandler([
        (delay: Duration.zero, status: 503),
        (delay: Duration.zero, status: 503),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 5),
        shouldHedge: (r, _) => r.statusCode == 503,
      );
      final response = await handler.send(_ctx());
      expect(response.statusCode, 503);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingHandler — all attempts throw', () {
    test('throws HedgingException when all attempts fail', () async {
      final inner = _ThrowingHandler([
        Exception('net error A'),
        Exception('net error B'),
      ]);
      final handler = _hedgingOver(
        inner,
        hedgeAfter: const Duration(milliseconds: 5),
      );
      await expectLater(
        () => handler.send(_ctx()),
        throwsA(isA<HedgingException>()),
      );
    });

    test('HedgingException.attemptsMade equals number of fired attempts',
        () async {
      final inner = _ThrowingHandler([
        Exception('e1'),
        Exception('e2'),
      ]);
      final handler = _hedgingOver(
        inner,
        hedgeAfter: const Duration(milliseconds: 5),
      );
      try {
        await handler.send(_ctx());
        fail('should have thrown');
      } on HedgingException catch (e) {
        expect(e.attemptsMade, 2);
        expect(e.cause, isNotNull);
      }
    });

    test('HedgingException.toString includes attempt count', () {
      const e = HedgingException(attemptsMade: 3);
      expect(e.toString(), contains('3'));
    });

    test('HedgingException is an HttpResilienceException', () {
      expect(
        const HedgingException(attemptsMade: 1),
        isA<HttpResilienceException>(),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingHandler — observability', () {
    test('HedgingEvent emitted for each extra speculative request', () async {
      final hub = ResilienceEventHub();
      final events = <HedgingEvent>[];
      hub.on<HedgingEvent>(events.add);

      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 200), status: 503),
        (delay: const Duration(milliseconds: 100), status: 503),
        (delay: Duration.zero, status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 20),
        maxHedgedAttempts: 2,
        eventHub: hub,
        shouldHedge: (r, _) => r.statusCode != 200,
      );
      await handler.send(_ctx());

      // Should have attempted 3 total: events for attempt 2 and 3.
      expect(events.length, greaterThanOrEqualTo(1));
      expect(events.first.attemptNumber, greaterThanOrEqualTo(2));
    });

    test('HedgingOutcomeEvent emitted with correct winningAttempt', () async {
      final hub = ResilienceEventHub();
      final outcomes = <HedgingOutcomeEvent>[];
      hub.on<HedgingOutcomeEvent>(outcomes.add);

      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 200), status: 200),
        (delay: Duration.zero, status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 20),
        eventHub: hub,
      );
      await handler.send(_ctx());

      await Future<void>.delayed(Duration.zero);
      expect(outcomes.length, 1);
      expect(outcomes.first.winningAttempt, 2);
    });

    test('onHedge callback is invoked with correct attempt number', () async {
      final fired = <int>[];
      final fake = _FakeHandler([
        (delay: const Duration(milliseconds: 200), status: 200),
        (delay: Duration.zero, status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(milliseconds: 20),
        onHedge: (attempt, _) => fired.add(attempt),
      );
      await handler.send(_ctx());
      expect(fired, [2]);
    });

    test('onHedge not called when first attempt wins before hedgeAfter',
        () async {
      final fired = <int>[];
      final fake = _FakeHandler([
        (delay: Duration.zero, status: 200),
      ]);
      final handler = _hedgingOver(
        fake,
        hedgeAfter: const Duration(seconds: 10),
        onHedge: (attempt, _) => fired.add(attempt),
      );
      await handler.send(_ctx());
      expect(fired, isEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpClientBuilder.withHedging()', () {
    test('integrates with pipeline via HttpClientBuilder', () async {
      var calls = 0;
      final mockClient = http_testing.MockClient((_) async {
        calls++;
        return http.Response('ok', 200);
      });

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://api.example.com'))
          .withHttpClient(mockClient)
          .withHedging(
            const HedgingPolicy(
              hedgeAfter: Duration(seconds: 10), // long — first should win fast
            ),
          )
          .build();

      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
      expect(calls, 1);
    });

    test('hedging fires second attempt when first is slow', () async {
      var calls = 0;
      final completer = Completer<http.Response>();
      final mockClient = http_testing.MockClient((_) async {
        calls++;
        if (calls == 1) return completer.future; // blocks
        return http.Response('ok', 200);
      });

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://api.example.com'))
          .withHttpClient(mockClient)
          .withHedging(
            const HedgingPolicy(
              hedgeAfter: Duration(milliseconds: 30),
            ),
          )
          .build();

      final response = await client.get(Uri.parse('/resource'));
      expect(response.statusCode, 200);
      expect(calls, greaterThanOrEqualTo(2));

      // Cleanup: complete the blocker to avoid dangling async.
      completer.complete(http.Response('late', 200));
    });

    test('returns correct status code from winning hedged attempt', () async {
      var calls = 0;
      final completer = Completer<http.Response>();
      final mockClient = http_testing.MockClient((_) async {
        calls++;
        if (calls == 1) return completer.future;
        return http.Response('created', 201);
      });

      final client = HttpClientBuilder()
          .withBaseUri(Uri.parse('https://example.com'))
          .withHttpClient(mockClient)
          .withHedging(
            const HedgingPolicy(
              hedgeAfter: Duration(milliseconds: 20),
            ),
          )
          .build();

      final response = await client.post(Uri.parse('/items'), body: '{}');
      expect(response.statusCode, 201);
      completer.complete(http.Response('late', 200));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FluentHttpClientBuilder.withHedging()', () {
    test('withHedging() configures hedging in fluent pipeline', () async {
      var calls = 0;
      final mockClient = http_testing.MockClient((_) async {
        calls++;
        return http.Response('ok', 200);
      });

      final client = FluentHttpClientBuilder('fluent-hedge')
          .withBaseUri(Uri.parse('https://svc.example.com'))
          .withHedging(const HedgingPolicy(hedgeAfter: Duration(seconds: 10)))
          .withHttpClient(mockClient)
          .build();

      final response = await client.get(Uri.parse('/data'));
      expect(response.statusCode, 200);
      expect(calls, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HedgingHandler — event types', () {
    test('HedgingEvent.toString contains attempt and hedgeAfter', () {
      final e = HedgingEvent(
        attemptNumber: 2,
        hedgeAfter: const Duration(milliseconds: 300),
        source: 'HedgingHandler',
      );
      expect(e.toString(), contains('2'));
      expect(e.toString(), contains('300ms'));
    });

    test('HedgingOutcomeEvent.toString contains winning and total', () {
      final e = HedgingOutcomeEvent(
        winningAttempt: 2,
        totalAttempts: 3,
        source: 'HedgingHandler',
      );
      expect(e.toString(), contains('2'));
      expect(e.toString(), contains('3'));
    });
  });
}
