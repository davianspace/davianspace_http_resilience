import '../core/http_response.dart';
import '../exceptions/circuit_open_exception.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import '../policies/circuit_breaker_policy.dart';
import 'resilience_policy.dart';

/// A predicate type for customising which circuit-breaker outcomes count.
typedef CircuitBreakerResultCondition = bool Function(
  dynamic result,
  Object? exception,
);

/// A [ResiliencePolicy] that implements the Circuit Breaker pattern for any
/// asynchronous operation — not just HTTP pipeline handlers.
///
/// The circuit transitions through three states:
///
/// | State          | Behaviour |
/// |----------------|-----------|
/// | **Closed**     | Requests pass through; failures increment the counter. |
/// | **Open**       | Requests are immediately rejected with [CircuitOpenException]. |
/// | **Half-Open**  | One probe request passes; success closes the circuit, failure re-opens it. |
///
/// ### Usage
/// ```dart
/// final policy = CircuitBreakerResiliencePolicy(
///   circuitName: 'payments-api',
///   failureThreshold: 5,
///   breakDuration: Duration(seconds: 30),
/// );
///
/// try {
///   final result = await policy.execute(() => makeRequest());
/// } on CircuitOpenException {
///   return cachedResult;
/// }
/// ```
///
/// ### Shared state via registry
/// All [CircuitBreakerResiliencePolicy] instances that share the same
/// [circuitName] and [`registry`] observe the same circuit state.
final class CircuitBreakerResiliencePolicy extends ResiliencePolicy {
  /// Creates a [CircuitBreakerResiliencePolicy].
  ///
  /// [circuitName]      — logical name used for diagnostics and registry keying.
  /// [failureThreshold] — consecutive failures before the circuit opens.
  /// [successThreshold] — consecutive successes in Half-Open to close the circuit.
  /// [breakDuration]    — how long the circuit stays open before probing.
  /// [shouldCount]      — custom predicate for counting failures; defaults to
  ///                      counting all exceptions and any result that is a
  ///                      5xx [HttpResponse].
  /// [registry]         — optional isolated registry; defaults to the process-
  ///                      wide [CircuitBreakerRegistry.instance].
  /// [onStateChange]    — optional list of callbacks fired on every state
  ///                      transition (Closed↔Open↔HalfOpen).
  CircuitBreakerResiliencePolicy({
    required this.circuitName,
    this.failureThreshold = 5,
    this.successThreshold = 1,
    this.breakDuration = const Duration(seconds: 30),
    CircuitBreakerResultCondition? shouldCount,
    CircuitBreakerRegistry? registry,
    List<CircuitStateChangeCallback>? onStateChange,
    ResilienceEventHub? eventHub,
  })  : _shouldCount = shouldCount,
        _state = (registry ?? CircuitBreakerRegistry.instance).getOrCreate(
          CircuitBreakerPolicy(
            circuitName: circuitName,
            failureThreshold: failureThreshold,
            successThreshold: successThreshold,
            breakDuration: breakDuration,
          ),
        ) {
    for (final cb in onStateChange ?? <CircuitStateChangeCallback>[]) {
      _state.addStateChangeListener(cb);
    }
    // Internal event hub listener — emits CircuitOpenEvent / CircuitCloseEvent.
    if (eventHub != null) {
      final hub = eventHub;
      _state.addStateChangeListener((from, to) {
        switch (to) {
          case CircuitState.open:
            hub.emit(
              CircuitOpenEvent(
                circuitName: circuitName,
                previousState: from,
                // closed→open = failureThreshold failures;
                // halfOpen→open = 1 probe failure.
                consecutiveFailures: from == CircuitState.closed
                    ? failureThreshold
                    : 1,
                source: 'CircuitBreakerResiliencePolicy',
              ),
            );
          case CircuitState.closed:
            hub.emit(
              CircuitCloseEvent(
                circuitName: circuitName,
                previousState: from,
                source: 'CircuitBreakerResiliencePolicy',
              ),
            );
          case CircuitState.halfOpen:
            break; // no dedicated event for half-open transition
        }
      });
    }
  }

  /// Logical name for this circuit.
  final String circuitName;

  /// Consecutive failures required to open the circuit.
  final int failureThreshold;

  /// Consecutive successes in Half-Open state required to close the circuit.
  final int successThreshold;

  /// How long the circuit remains open before transitioning to Half-Open.
  final Duration breakDuration;

  final CircuitBreakerResultCondition? _shouldCount;
  final CircuitBreakerState _state;

  /// The current observable state of the circuit.
  CircuitState get circuitState => _state.state;

  /// A point-in-time snapshot of call and transition metrics for this circuit.
  ///
  /// ```dart
  /// final m = policy.metrics;
  /// print('failed: ${m.failedCalls}, rejected: ${m.rejectedCalls}');
  /// ```
  CircuitBreakerMetrics get metrics => _state.metrics;

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    if (!_state.isAllowing) {
      _state.recordRejected();
      throw CircuitOpenException(
        circuitName: circuitName,
        retryAfter: _state.retryAfter,
      );
    }

    try {
      final result = await action();

      if (_countsAsFailure(result, null)) {
        _state.recordFailure();
      } else {
        _state.recordSuccess();
      }

      return result;
    } catch (e) {
      if (_countsAsFailure(null, e)) {
        _state.recordFailure();
      } else {
        _state.recordSuccess();
      }
      rethrow;
    }
  }

  bool _countsAsFailure(dynamic result, Object? exception) {
    final predicate = _shouldCount;
    if (predicate != null) return predicate(result, exception);
    // Default: count all exceptions and 5xx HttpResponse results.
    if (exception != null) return true;
    if (result is HttpResponse) return result.isServerError;
    return false;
  }

  /// Manually resets the circuit to [CircuitState.closed].
  void reset() => _state.reset();

  @override
  String toString() => 'CircuitBreakerResiliencePolicy('
      'circuit=$circuitName, state=$circuitState)';
}
