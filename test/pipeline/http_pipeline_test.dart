import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
// Import internal pipeline types directly — they are @internal (not part of the
// public API) but tests may still reference them by importing via src path.
import 'package:davianspace_http_resilience/src/pipeline/http_pipeline_builder.dart';
import 'package:davianspace_http_resilience/src/pipeline/terminal_handler.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test Doubles
// ════════════════════════════════════════════════════════════════════════════

/// A configurable stub that extends [HttpHandler] directly, acting as a
/// non-delegating terminal.  It never calls an inner handler.
final class StubTerminal extends HttpHandler {
  StubTerminal({
    HttpResponse? response,
    Exception? throws,
    Duration delay = Duration.zero,
  })  : _response = response ?? HttpResponse.ok(),
        _throws = throws,
        _delay = delay;

  final HttpResponse _response;
  final Exception? _throws;
  final Duration _delay;

  int callCount = 0;
  final List<HttpContext> capturedContexts = [];

  @override
  Future<HttpResponse> send(HttpContext context) async {
    callCount++;
    capturedContexts.add(context);
    if (_delay > Duration.zero) await Future<void>.delayed(_delay);
    final e = _throws;
    if (e != null) throw e;
    return _response;
  }
}

/// Records pre- and post-processing events in [eventLog] and optionally
/// mutates the request / response or short-circuits / catches exceptions.
final class RecordingHandler extends DelegatingHandler {
  RecordingHandler(
    this.name,
    this.eventLog, {
    this.mutateRequestHeader,
    this.mutateResponseStatus,
    this.catchExceptions = false,
    this.shortCircuit = false,
    HttpResponse? shortCircuitResponse,
  }) : _shortCircuitResponse = shortCircuitResponse ?? HttpResponse.ok();

  final String name;
  final List<String> eventLog;
  final String? mutateRequestHeader;
  final int? mutateResponseStatus;
  final bool catchExceptions;
  final bool shortCircuit;
  final HttpResponse _shortCircuitResponse;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    eventLog.add('$name.before');

    if (mutateRequestHeader != null) {
      context.updateRequest(
        context.request.withHeader(mutateRequestHeader!, name),
      );
    }

    if (shortCircuit) {
      eventLog.add('$name.shortCircuit');
      return _shortCircuitResponse;
    }

    HttpResponse response;
    try {
      response = await innerHandler.send(context);
    } catch (e) {
      if (catchExceptions) {
        eventLog.add('$name.caught(${e.runtimeType})');
        return HttpResponse.serviceUnavailable();
      }
      eventLog.add('$name.propagated(${e.runtimeType})');
      rethrow;
    }

    if (mutateResponseStatus != null) {
      response = response.copyWith(statusCode: mutateResponseStatus);
    }

    eventLog.add('$name.after');
    return response;
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

HttpContext makeContext({String? url}) => HttpContext(
      request: HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse(url ?? 'https://example.com/test'),
      ),
    );

/// Creates a [TerminalHandler] backed by a [`MockClient`] that always returns
/// [status] with optional [body].
TerminalHandler mockTerminal(int status, {String body = ''}) => TerminalHandler(
      client: http_testing.MockClient(
        (_) async => http.Response(body, status),
      ),
    );

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  group('HttpPipeline — list constructor', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('single DelegatingHandler is wired to the stub terminal', () async {
      final log = <String>[];
      final handler = RecordingHandler('A', log);
      final terminal = StubTerminal();
      final pipeline = HttpPipeline([handler, terminal]);

      await pipeline.send(makeContext());
      expect(log, ['A.before', 'A.after']);
      expect(terminal.callCount, 1);
    });

    test('last DelegatingHandler auto-appends real TerminalHandler', () {
      // When all items are DelegatingHandler, a TerminalHandler is appended.
      final solo = RecordingHandler('solo', []);
      expect(solo.hasInnerHandler, isFalse); // unwired before construction
      final pipeline = HttpPipeline([solo]);
      // chain = solo → auto-TerminalHandler → length = 2
      expect(solo.hasInnerHandler, isTrue); // wired by HttpPipeline
      expect(pipeline.length, 2);
    });

    test('explicit non-DelegatingHandler terminal is NOT auto-wrapped', () {
      final terminal = StubTerminal();
      final pipeline = HttpPipeline([
        RecordingHandler('A', []),
        terminal,
      ]);
      // chain = A → terminal → length = 2
      expect(pipeline.length, 2);
    });

    test('three DelegatingHandlers plus explicit terminal → length = 4', () {
      final terminal = StubTerminal();
      final pipeline = HttpPipeline([
        RecordingHandler('A', []),
        RecordingHandler('B', []),
        RecordingHandler('C', []),
        terminal,
      ]);
      expect(pipeline.length, 4);
    });

    test('throws ArgumentError for non-DelegatingHandler in non-terminal slot',
        () {
      // NoOpPipeline extends HttpHandler (not DelegatingHandler)
      const nonDelegating = NoOpPipeline();
      expect(
        () => HttpPipeline([nonDelegating, StubTerminal()]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('root references the outermost handler', () {
      final outer = RecordingHandler('outer', []);
      final terminal = StubTerminal();
      final pipeline = HttpPipeline([outer, terminal]);
      expect(pipeline.root, same(outer));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Execution order', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('pre and post phases execute in correct stack order', () async {
      final log = <String>[];
      final pipeline = HttpPipeline([
        RecordingHandler('1', log),
        RecordingHandler('2', log),
        RecordingHandler('3', log),
        StubTerminal(),
      ]);

      await pipeline.send(makeContext());

      expect(log, [
        '1.before',
        '2.before',
        '3.before',
        '3.after',
        '2.after',
        '1.after',
      ]);
    });

    test('terminal is called once per send; two sends → two calls', () async {
      final terminal = StubTerminal();
      final pipeline = HttpPipeline([
        RecordingHandler('A', []),
        terminal,
      ]);

      await pipeline.send(makeContext());
      await pipeline.send(makeContext());
      expect(terminal.callCount, 2);
    });

    test('each middleware in a four-handler chain runs exactly once', () async {
      var invokeCount = 0;
      final terminal = StubTerminal();
      final pipeline = HttpPipeline([
        _CountingHandler(() => invokeCount++),
        _CountingHandler(() => invokeCount++),
        _CountingHandler(() => invokeCount++),
        _CountingHandler(() => invokeCount++),
        terminal,
      ]);

      await pipeline.send(makeContext());
      expect(invokeCount, 4);
      expect(terminal.callCount, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Request modification', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('outer handler injects a request header visible to inner', () async {
      final terminal = StubTerminal();
      final injector = RecordingHandler(
        'injector',
        [],
        mutateRequestHeader: 'X-Added-By',
      );

      final pipeline = HttpPipeline([injector, terminal]);
      await pipeline.send(makeContext());

      final req = terminal.capturedContexts.first.request;
      expect(req.headers['X-Added-By'], 'injector');
    });

    test('multiple handlers inject headers cumulatively', () async {
      final terminal = StubTerminal();
      final a = RecordingHandler('A', [], mutateRequestHeader: 'X-Handler-A');
      final b = RecordingHandler('B', [], mutateRequestHeader: 'X-Handler-B');

      final pipeline = HttpPipeline([a, b, terminal]);
      await pipeline.send(makeContext());

      final req = terminal.capturedContexts.first.request;
      expect(req.headers['X-Handler-A'], 'A');
      expect(req.headers['X-Handler-B'], 'B');
    });

    test('inner terminal sees request mutations made by outer handler',
        () async {
      final terminal = StubTerminal();
      final outer = RecordingHandler(
        'outer',
        [],
        mutateRequestHeader: 'X-Trace',
      );

      final pipeline = HttpPipeline([outer, terminal]);
      await pipeline.send(makeContext());

      final seen = terminal.capturedContexts.first.request;
      expect(seen.headers['X-Trace'], 'outer');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Response modification', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('handler rewrites response status code', () async {
      final terminal = StubTerminal(
        response: HttpResponse(statusCode: 200),
      );
      final rewriter = RecordingHandler(
        'rewriter',
        [],
        mutateResponseStatus: 202,
      );

      final pipeline = HttpPipeline([rewriter, terminal]);
      final response = await pipeline.send(makeContext());

      expect(response.statusCode, 202);
    });

    test('outer handler sees the response mutated by inner handler', () async {
      final terminal = StubTerminal(
        response: HttpResponse(statusCode: 200),
      );
      // inner: 200 → 201; outer: 201 → 204
      final inner = RecordingHandler('inner', [], mutateResponseStatus: 201);
      final outer = RecordingHandler('outer', [], mutateResponseStatus: 204);

      final pipeline = HttpPipeline([outer, inner, terminal]);
      final response = await pipeline.send(makeContext());

      expect(response.statusCode, 204);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Exception propagation', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('exception from terminal propagates through all handlers', () async {
      final log = <String>[];
      final terminal = StubTerminal(throws: _TestException('network down'));
      final a = RecordingHandler('A', log);
      final b = RecordingHandler('B', log);

      final pipeline = HttpPipeline([a, b, terminal]);

      await expectLater(
        pipeline.send(makeContext()),
        throwsA(isA<_TestException>()),
      );

      expect(log, [
        'A.before',
        'B.before',
        'B.propagated(_TestException)',
        'A.propagated(_TestException)',
      ]);
    });

    test('middleware can catch exception and return a fallback response',
        () async {
      final log = <String>[];
      final terminal = StubTerminal(throws: _TestException('service error'));
      final catcher = RecordingHandler('catcher', log, catchExceptions: true);

      final pipeline = HttpPipeline([catcher, terminal]);
      final response = await pipeline.send(makeContext());

      expect(response.statusCode, 503);
      expect(log, contains('catcher.caught(_TestException)'));
    });

    test('exception caught by inner handler does not reach outer handler',
        () async {
      final log = <String>[];
      final terminal = StubTerminal(throws: _TestException('db error'));
      final outer = RecordingHandler('outer', log);
      final catcher = RecordingHandler('catcher', log, catchExceptions: true);

      final pipeline = HttpPipeline([outer, catcher, terminal]);
      final response = await pipeline.send(makeContext());

      expect(response.isServerError, isTrue);
      expect(log, [
        'outer.before',
        'catcher.before',
        'catcher.caught(_TestException)',
        'outer.after',
      ]);
    });

    test('CancellationException propagates when token is already cancelled',
        () async {
      final token = CancellationToken()..cancel('test abort');

      final ctx = HttpContext(
        request: HttpRequest(
          method: HttpMethod.get,
          uri: Uri.parse('https://example.com'),
        ),
        cancellationToken: token,
      );
      final pipeline = HttpPipeline([
        _CancellationGuardHandler(),
        StubTerminal(),
      ]);

      await expectLater(
        pipeline.send(ctx),
        throwsA(isA<CancellationException>()),
      );
    });

    test('RetryExhaustedException after maxRetries + 1 total attempts',
        () async {
      final policy = RetryPolicy.constant(
        maxRetries: 2,
        delay: Duration.zero,
      );
      final terminal = StubTerminal(throws: _TestException('flaky'));
      final pipeline = HttpPipeline([
        RetryHandler(policy),
        terminal,
      ]);

      await expectLater(
        pipeline.send(makeContext()),
        throwsA(isA<RetryExhaustedException>()),
      );
      expect(terminal.callCount, 3); // 1 initial + 2 retries
    });

    test('CircuitOpenException after failure threshold is exceeded', () async {
      final registry = CircuitBreakerRegistry();
      const policy = CircuitBreakerPolicy(
        circuitName: 'exc-test',
        failureThreshold: 1,
      );
      // 503 response → shouldCount → trips circuit after first call
      final terminal = StubTerminal(
        response: HttpResponse(statusCode: 503),
      );
      final pipeline = HttpPipeline([
        CircuitBreakerHandler(policy, registry: registry),
        terminal,
      ]);

      await pipeline.send(makeContext()); // first call trips circuit

      await expectLater(
        pipeline.send(makeContext()),
        throwsA(isA<CircuitOpenException>()),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Short-circuit', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('handler returning early prevents inner handler from executing',
        () async {
      final log = <String>[];
      final terminal = StubTerminal();
      final sc = RecordingHandler(
        'sc',
        log,
        shortCircuit: true,
        shortCircuitResponse: HttpResponse(statusCode: 418),
      );
      sc.innerHandler = terminal;

      final response = await sc.send(makeContext());

      expect(response.statusCode, 418);
      expect(terminal.callCount, 0);
      expect(log, ['sc.before', 'sc.shortCircuit']);
    });

    test('short-circuit via HttpPipeline — inner terminal never called',
        () async {
      final terminal = StubTerminal();
      final sc = RecordingHandler(
        'cache',
        [],
        shortCircuit: true,
        shortCircuitResponse: HttpResponse.ok(body: [1, 2, 3]),
      );

      final pipeline = HttpPipeline([sc, terminal]);
      final response = await pipeline.send(makeContext());

      expect(response.isSuccess, isTrue);
      expect(terminal.callCount, 0);
    });

    test('outer handler completes normally after inner short-circuits',
        () async {
      final log = <String>[];
      final terminal = StubTerminal();
      final outer = RecordingHandler('outer', log);
      final sc = RecordingHandler(
        'sc',
        log,
        shortCircuit: true,
        shortCircuitResponse: HttpResponse(statusCode: 202),
      );

      final pipeline = HttpPipeline([outer, sc, terminal]);
      final response = await pipeline.send(makeContext());

      expect(response.statusCode, 202);
      expect(terminal.callCount, 0);
      expect(log, [
        'outer.before',
        'sc.before',
        'sc.shortCircuit',
        'outer.after',
      ]);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('Concurrent execution', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('five concurrent sends all succeed independently', () async {
      final terminal = StubTerminal(delay: const Duration(milliseconds: 10));
      final pipeline = HttpPipeline([
        RecordingHandler('A', []),
        terminal,
      ]);

      final responses = await Future.wait(
        List.generate(5, (_) => pipeline.send(makeContext())),
      );

      expect(responses, hasLength(5));
      expect(responses.every((r) => r.isSuccess), isTrue);
      expect(terminal.callCount, 5);
    });

    test('request mutations do not cross-contaminate across concurrent sends',
        () async {
      final terminal = StubTerminal(delay: const Duration(milliseconds: 5));
      final pipeline = HttpPipeline([
        RecordingHandler('A', [], mutateRequestHeader: 'X-RequestId'),
        terminal,
      ]);

      await Future.wait(
        List.generate(10, (i) {
          return pipeline.send(
            HttpContext(
              request: HttpRequest(
                method: HttpMethod.get,
                uri: Uri.parse('https://example.com/$i'),
              ),
            ),
          );
        }),
      );

      for (final ctx in terminal.capturedContexts) {
        expect(ctx.request.headers['X-RequestId'], 'A');
      }
    });

    test('setProperty is per-context and does not leak between sends',
        () async {
      final results = <Object?>[];
      final pipeline = HttpPipeline([
        _PropertyRecorderHandler('myKey', results),
        StubTerminal(),
      ]);

      final ctx1 = makeContext()..setProperty('myKey', 'ctx-1-value');
      final ctx2 = makeContext()..setProperty('myKey', 'ctx-2-value');

      await Future.wait([pipeline.send(ctx1), pipeline.send(ctx2)]);

      expect(results, containsAll(['ctx-1-value', 'ctx-2-value']));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('HttpPipelineBuilder integration', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('builder and list-constructor produce equivalent execution order',
        () async {
      final log1 = <String>[];
      final log2 = <String>[];

      // List constructor with stub terminal
      final t1 = StubTerminal();
      final listPipeline = HttpPipeline([
        RecordingHandler('A', log1),
        RecordingHandler('B', log1),
        t1,
      ]);

      // Builder with MockClient-backed terminal
      final t2 = mockTerminal(200);
      final builtHandler = (HttpPipelineBuilder()
            ..addHandler(RecordingHandler('A', log2))
            ..addHandler(RecordingHandler('B', log2))
            ..withTerminalHandler(t2))
          .build();

      await listPipeline.send(makeContext());
      await builtHandler.send(makeContext());

      expect(log1, log2);
      expect(t1.callCount, 1);
    });

    test('builder.build() returns the outermost handler as root', () {
      final t = mockTerminal(200);
      final a = RecordingHandler('A', []);
      final built = (HttpPipelineBuilder()
            ..addHandler(a)
            ..withTerminalHandler(t))
          .build();
      expect(built, same(a));
    });

    test('empty builder returns the terminal handler directly', () {
      final t = mockTerminal(200);
      final built = (HttpPipelineBuilder()..withTerminalHandler(t)).build();
      expect(built, same(t));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('DelegatingHandler wiring', () {
    // ──────────────────────────────────────────────────────────────────────────

    test('hasInnerHandler is false before wiring', () {
      expect(RecordingHandler('A', []).hasInnerHandler, isFalse);
    });

    test('hasInnerHandler is true after innerHandler is assigned', () {
      final h = RecordingHandler('A', []);
      h.innerHandler = StubTerminal();
      expect(h.hasInnerHandler, isTrue);
    });

    test('accessing innerHandler before assignment throws StateError', () {
      expect(() => RecordingHandler('A', []).innerHandler, throwsStateError);
    });

    test('innerHandler can be reassigned', () async {
      final h = RecordingHandler('A', []);
      final t1 = StubTerminal(response: HttpResponse(statusCode: 201));
      final t2 = StubTerminal(response: HttpResponse(statusCode: 202));

      h.innerHandler = t1;
      final r1 = await h.send(makeContext());

      h.innerHandler = t2;
      final r2 = await h.send(makeContext());

      expect(r1.statusCode, 201);
      expect(r2.statusCode, 202);
    });
  });
}

// ════════════════════════════════════════════════════════════════════════════
//  Test-only exception with a predictable runtimeType
// ════════════════════════════════════════════════════════════════════════════

/// Use this instead of [Exception] so [runtimeType.toString()] is predictable.
/// Dart's `Exception()` factory creates `_Exception` (private), not `Exception`.
final class _TestException implements Exception {
  _TestException(this.message);
  final String message;
  @override
  String toString() => '_TestException: $message';
}

// ════════════════════════════════════════════════════════════════════════════
//  Support handlers used only in tests
// ════════════════════════════════════════════════════════════════════════════

/// Calls [`_onInvoke`] before delegating to the inner handler.
final class _CountingHandler extends DelegatingHandler {
  _CountingHandler(this._onInvoke);
  final void Function() _onInvoke;

  @override
  Future<HttpResponse> send(HttpContext context) {
    _onInvoke();
    return innerHandler.send(context);
  }
}

/// Guards against cancelled tokens and delegates to innerHandler.
/// Must be `async` so synchronous exceptions are wrapped in a Future.
final class _CancellationGuardHandler extends DelegatingHandler {
  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();
    return innerHandler.send(context);
  }
}

/// Reads a property from context after the inner response and records it.
final class _PropertyRecorderHandler extends DelegatingHandler {
  _PropertyRecorderHandler(this._key, this._results);

  final String _key;
  final List<Object?> _results;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    final response = await innerHandler.send(context);
    _results.add(context.getProperty<String>(_key));
    return response;
  }
}
