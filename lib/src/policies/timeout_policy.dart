/// Immutable configuration for the timeout policy.
///
/// [TimeoutPolicy] wraps [`Future.timeout`] semantics with pipeline-friendly
/// configuration. When the timeout is exceeded the handler throws an
/// [`HttpTimeoutException`].
///
/// ```dart
/// final policy = TimeoutPolicy(timeout: Duration(seconds: 10));
/// ```
final class TimeoutPolicy {
  const TimeoutPolicy({
    required this.timeout,
    this.perRetry = false,
  });

  /// The maximum duration allowed for a single attempt.
  final Duration timeout;

  /// When `true`, the timeout is applied independently to each retry attempt.
  /// When `false` (default), the timeout is applied to the entire operation
  /// including all retries.
  final bool perRetry;

  @override
  String toString() =>
      'TimeoutPolicy(timeout=${timeout.inMilliseconds}ms, perRetry=$perRetry)';
}
