import 'http_resilience_exception.dart';

/// Thrown when all configured retry attempts are exhausted without a
/// successful response.
///
/// Carries the [attemptsMade] count so callers can inspect how many
/// retries were performed before giving up.
class RetryExhaustedException extends HttpResilienceException {
  /// Creates a [RetryExhaustedException].
  ///
  /// [attemptsMade] — total number of attempts, including the initial one.
  const RetryExhaustedException({
    required this.attemptsMade,
    Object? cause,
    StackTrace? stackTrace,
  }) : super(
         'All $attemptsMade HTTP attempt(s) failed.',
         cause: cause,
         stackTrace: stackTrace,
       );

  /// The total number of attempts made (1 + retries configured).
  final int attemptsMade;

  @override
  String toString() =>
      'RetryExhaustedException: attempts=$attemptsMade — ${super.toString()}';
}
