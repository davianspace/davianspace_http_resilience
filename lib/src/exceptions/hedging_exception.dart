import 'http_resilience_exception.dart';

/// Thrown when all hedged attempts are exhausted without any of them
/// returning a "winning" response.
///
/// A "winning" response is a 2xx result by default, or whatever
/// `HedgingPolicy.shouldHedge` classifies as acceptable.
///
/// [attemptsMade] reflects the total number of concurrent speculative
/// requests that were fired before giving up.
///
/// ## Example
///
/// ```dart
/// try {
///   final response = await client.get(Uri.parse('/resource'));
/// } on HedgingException catch (e) {
///   print('All ${e.attemptsMade} hedged attempts failed: ${e.cause}');
/// }
/// ```
class HedgingException extends HttpResilienceException {
  /// Creates a [HedgingException].
  ///
  /// [attemptsMade] — total number of concurrent attempts that were fired.
  /// [cause]        — the last exception that caused the final attempt to fail,
  ///                  or `null` when all attempts returned non-winning responses.
  /// [stackTrace]   — stack trace for [cause], when available.
  const HedgingException({
    required this.attemptsMade,
    Object? cause,
    StackTrace? stackTrace,
  }) : super(
          'All $attemptsMade hedged HTTP attempt(s) failed to produce an '
          'acceptable response.',
          cause: cause,
          stackTrace: stackTrace,
        );

  /// Total number of concurrent speculative requests that were fired.
  ///
  /// Equals `HedgingPolicy.maxHedgedAttempts + 1` in the typical case
  /// where every available attempt slot was consumed before a winner was found.
  final int attemptsMade;

  @override
  String toString() =>
      'HedgingException: attempts=$attemptsMade — ${super.toString()}';
}
