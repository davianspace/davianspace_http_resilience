import 'http_resilience_exception.dart';

/// Thrown when a request is rejected because the circuit breaker is in
/// the **Open** state, i.e. the failure threshold has been exceeded and
/// the cool-down period has not yet elapsed.
class CircuitOpenException extends HttpResilienceException {
  /// Creates a [CircuitOpenException].
  ///
  /// [circuitName] identifies the circuit that is open.
  /// [retryAfter] is the earliest point at which the circuit will attempt
  /// to transition to the Half-Open state again.
  const CircuitOpenException({required this.circuitName, this.retryAfter})
    : super(
        'Circuit "$circuitName" is open. Requests rejected until '
        '${retryAfter ?? "the circuit recovers"}.',
      );

  /// The logical name of the circuit that rejected the request.
  final String circuitName;

  /// The earliest [DateTime] at which the circuit will test again (optional).
  final DateTime? retryAfter;

  @override
  String toString() =>
      'CircuitOpenException: circuit=$circuitName retryAfter=$retryAfter';
}
