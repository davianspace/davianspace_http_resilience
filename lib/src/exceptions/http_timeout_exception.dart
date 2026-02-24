import 'http_resilience_exception.dart';

/// Thrown when a request or execution stage exceeds its allowed [timeout].
class HttpTimeoutException extends HttpResilienceException {
  /// Creates an [HttpTimeoutException].
  ///
  /// [timeout] is the duration that was exceeded.
  HttpTimeoutException({
    required this.timeout,
    Object? cause,
    StackTrace? stackTrace,
  }) : super(
          'Operation timed out after ${timeout.inMilliseconds} ms.',
          cause: cause,
          stackTrace: stackTrace,
        );

  /// The duration threshold that was exceeded.
  final Duration timeout;

  @override
  String toString() =>
      'HttpTimeoutException: timeout=${timeout.inMilliseconds}ms';
}
