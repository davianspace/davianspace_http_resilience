/// Base exception for all errors originating from the
/// `davianspace_http_resilience` pipeline.
///
/// All concrete exception types in this package extend [HttpResilienceException]
/// so callers can catch the entire family with a single `on` clause.
class HttpResilienceException implements Exception {
  /// Creates an [HttpResilienceException] with a mandatory [message] and an
  /// optional [cause] (underlying error) and [stackTrace].
  const HttpResilienceException(this.message, {this.cause, this.stackTrace});

  /// Human-readable description of the failure.
  final String message;

  /// The original error that triggered this exception, if any.
  final Object? cause;

  /// Stack trace captured at the point of origin, if available.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('HttpResilienceException: $message');
    if (cause != null) buffer.write('\nCaused by: $cause');
    return buffer.toString();
  }
}
