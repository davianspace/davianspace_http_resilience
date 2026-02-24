import '../core/http_context.dart';
import '../core/http_response.dart';
import '../exceptions/circuit_open_exception.dart';
import '../pipeline/delegating_handler.dart';
import '../policies/circuit_breaker_policy.dart';

/// A [DelegatingHandler] that implements the Circuit Breaker pattern.
///
/// The handler consults a shared [CircuitBreakerState] (keyed by
/// [CircuitBreakerPolicy.circuitName] in the [CircuitBreakerRegistry]) before
/// every request:
///
/// * **Closed** — request is forwarded; outcomes update the failure counter.
/// * **Open**   — request is immediately rejected with [CircuitOpenException].
/// * **Half-Open** — one probe request passes; success closes the circuit,
///   failure re-opens it.
///
/// ### Example
/// ```dart
/// final policy = CircuitBreakerPolicy(
///   circuitName: 'inventory-api',
///   failureThreshold: 5,
///   breakDuration: Duration(seconds: 30),
/// );
/// final handler = CircuitBreakerHandler(policy);
/// ```
final class CircuitBreakerHandler extends DelegatingHandler {
  CircuitBreakerHandler(
    CircuitBreakerPolicy policy, {
    CircuitBreakerRegistry? registry,
  })  : _state = (registry ?? CircuitBreakerRegistry.instance)
            .getOrCreate(policy),
        _policy = policy,
        super();

  final CircuitBreakerPolicy _policy;
  final CircuitBreakerState _state;

  /// The current observable state of the circuit.
  CircuitState get circuitState => _state.state;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    if (!_state.isAllowing) {
      _state.recordRejected();
      throw CircuitOpenException(
        circuitName: _policy.circuitName,
        retryAfter: _state.retryAfter,
      );
    }

    try {
      final response = await innerHandler.send(context);

      if (_policy.shouldCount(response, null)) {
        _state.recordFailure();
      } else {
        _state.recordSuccess();
      }

      return response;
    } catch (e) {
      if (_policy.shouldCount(null, e)) {
        _state.recordFailure();
      } else {
        _state.recordSuccess();
      }
      rethrow;
    }
  }
}
