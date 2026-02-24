import 'dart:async';

import '../exceptions/http_timeout_exception.dart';
import '../observability/resilience_event.dart';
import '../observability/resilience_event_hub.dart';
import 'resilience_policy.dart';

/// A [ResiliencePolicy] that cancels the action when it exceeds [timeout].
///
/// Throws [HttpTimeoutException] if the action does not complete within the
/// configured duration.
///
/// ### Usage
/// ```dart
/// final policy = TimeoutResiliencePolicy(Duration(seconds: 10));
///
/// try {
///   final result = await policy.execute(() => makeRequest());
/// } on HttpTimeoutException catch (e) {
///   print('Timed out after ${e.timeout.inSeconds}s');
/// }
/// ```
///
/// ### Composition
/// Combine with [`RetryResiliencePolicy`] to enforce per-attempt or total
/// timeouts:
/// ```dart
/// // Per-attempt timeout: each retry gets its own 5-second budget.
/// final policy = Policy.retry(maxRetries: 3)
///     .wrap(Policy.timeout(Duration(seconds: 5)));
///
/// // Total-operation timeout: all retries must finish within 15 seconds.
/// final policy = Policy.timeout(Duration(seconds: 15))
///     .wrap(Policy.retry(maxRetries: 3));
/// ```
final class TimeoutResiliencePolicy extends ResiliencePolicy {
  /// Creates a [TimeoutResiliencePolicy] with the given [timeout].
  ///
  /// Pass [eventHub] to receive a [TimeoutEvent] whenever an action times out.
  const TimeoutResiliencePolicy(
    this.timeout, {
    this.eventHub,
  });

  /// The maximum duration allowed for the action to complete.
  final Duration timeout;

  /// Optional [ResilienceEventHub] that receives a [TimeoutEvent] when the
  /// action exceeds [timeout].
  ///
  /// Events are dispatched via [scheduleMicrotask] and never block execution.
  final ResilienceEventHub? eventHub;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(timeout);
    } on TimeoutException catch (e) {
      final ex = HttpTimeoutException(timeout: timeout, cause: e);
      eventHub?.emit(
        TimeoutEvent(
          timeout: timeout,
          exception: ex,
          source: 'TimeoutResiliencePolicy',
        ),
      );
      throw ex;
    }
  }

  @override
  String toString() => 'TimeoutResiliencePolicy(${timeout.inMilliseconds}ms)';
}
