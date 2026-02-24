import 'dart:math' as math;

import '../core/cancellation_token.dart';
import '../core/http_context.dart';
import '../core/http_response.dart';
import '../resilience/outcome_classification.dart';

/// Determines whether an [HttpResponse] or thrown exception should trigger
/// a retry attempt.
///
/// Supply a custom [RetryPredicate] to [RetryPolicy] when the default
/// (5xx + network exceptions) is not sufficient for your use-case.
typedef RetryPredicate = bool Function(
  HttpResponse? response,
  Object? exception,
  HttpContext context,
);

/// Computes the delay to apply before a retry attempt.
///
/// [retryCount] is the 1-based attempt index (1 = first retry, 2 = second…).
typedef DelayProvider = Duration Function(int retryCount);

/// Immutable configuration for the retry policy.
///
/// Use the factory constructors ([RetryPolicy.constant],
/// [RetryPolicy.linear], [RetryPolicy.exponential]) for the most common
/// back-off strategies. Fine-tune with [RetryPolicy.custom].
///
/// ```dart
/// // Three retries with exponential back-off and jitter
/// final policy = RetryPolicy.exponential(
///   maxRetries: 3,
///   baseDelay: Duration(milliseconds: 200),
///   useJitter: true,
/// );
/// ```
final class RetryPolicy {
  RetryPolicy._({  // non-const: CancellationToken is not const-constructable
    required this.maxRetries,
    required this.delayProvider,
    required this.shouldRetry,
    this.respectRetryAfterHeader = false,
    this.maxRetryAfterDelay,
    this.cancellationToken,
  });

  // -------------------------------------------------------------------------
  // Built-in factory constructors
  // -------------------------------------------------------------------------

  /// Retries up to [maxRetries] times with a fixed [delay].
  ///
  /// When [classifier] is supplied it takes precedence over [shouldRetry].
  factory RetryPolicy.constant({
    required int maxRetries,
    Duration delay = const Duration(milliseconds: 200),
    RetryPredicate? shouldRetry,
    OutcomeClassifier? classifier,
  }) =>
      RetryPolicy._(
        maxRetries: maxRetries,
        delayProvider: (_) => delay,
        shouldRetry: classifier != null
            ? _predicateFromClassifier(classifier)
            : (shouldRetry ?? _defaultShouldRetry),
      );

  /// Retries with linearly increasing delays: `delay * retryCount`.
  ///
  /// When [classifier] is supplied it takes precedence over [shouldRetry].
  factory RetryPolicy.linear({
    required int maxRetries,
    Duration baseDelay = const Duration(milliseconds: 200),
    RetryPredicate? shouldRetry,
    OutcomeClassifier? classifier,
  }) =>
      RetryPolicy._(
        maxRetries: maxRetries,
        delayProvider: (n) => baseDelay * n,
        shouldRetry: classifier != null
            ? _predicateFromClassifier(classifier)
            : (shouldRetry ?? _defaultShouldRetry),
      );

  /// Retries with exponential back-off: `baseDelay * 2^(retryCount-1)`.
  ///
  /// When [useJitter] is `true`, introduces up to 25 % random jitter to
  /// avoid thundering-herd problems (full jitter strategy).
  ///
  /// When [classifier] is supplied it takes precedence over [shouldRetry].
  factory RetryPolicy.exponential({
    required int maxRetries,
    Duration baseDelay = const Duration(milliseconds: 200),
    Duration maxDelay = const Duration(seconds: 30),
    bool useJitter = false,
    RetryPredicate? shouldRetry,
    OutcomeClassifier? classifier,
  }) {
    return RetryPolicy._(
      maxRetries: maxRetries,
      delayProvider: (n) {
        final expMs = baseDelay.inMilliseconds * (1 << (n - 1));
        final cappedMs = expMs.clamp(0, maxDelay.inMilliseconds);
        if (!useJitter) return Duration(milliseconds: cappedMs);
        // Add up to 25 % jitter
        final jitterMs = (cappedMs * 0.25 * _random()).round();
        return Duration(milliseconds: cappedMs + jitterMs);
      },
      shouldRetry: classifier != null
          ? _predicateFromClassifier(classifier)
          : (shouldRetry ?? _defaultShouldRetry),
    );
  }

  /// Fully customisable retry policy.
  ///
  /// When [classifier] is supplied it takes precedence over [shouldRetry].
  factory RetryPolicy.custom({
    required int maxRetries,
    required DelayProvider delayProvider,
    RetryPredicate? shouldRetry,
    OutcomeClassifier? classifier,
  }) =>
      RetryPolicy._(
        maxRetries: maxRetries,
        delayProvider: delayProvider,
        shouldRetry: classifier != null
            ? _predicateFromClassifier(classifier)
            : (shouldRetry ?? _defaultShouldRetry),
      );

  /// Creates a [RetryPolicy] driven entirely by an [OutcomeClassifier].
  ///
  /// [classifier] replaces all predicate logic: the policy retries whenever
  /// [OutcomeClassifier.classify] returns [OutcomeClassification.transientFailure].
  ///
  /// ```dart
  /// final policy = RetryPolicy.withClassifier(
  ///   maxRetries: 3,
  ///   classifier: ThrottleAwareClassifier(),
  /// );
  /// ```
  factory RetryPolicy.withClassifier({
    required int maxRetries,
    required OutcomeClassifier classifier,
    DelayProvider delayProvider = _noDelay,
  }) =>
      RetryPolicy._(
        maxRetries: maxRetries,
        delayProvider: delayProvider,
        shouldRetry: _predicateFromClassifier(classifier),
      );

  // -------------------------------------------------------------------------
  // Fields
  // -------------------------------------------------------------------------

  /// Maximum number of retry attempts (not counting the initial request).
  final int maxRetries;

  /// Provides the delay duration for each retry attempt.
  final DelayProvider delayProvider;

  /// Decides whether a given response or exception warrants a retry.
  final RetryPredicate shouldRetry;

  /// When `true`, the retry handler reads the `Retry-After` response header
  /// (numeric seconds only) and uses that duration as the back-off delay
  /// instead of the computed delay from [delayProvider].
  ///
  /// Capped at [maxRetryAfterDelay] when set. Defaults to `false`.
  final bool respectRetryAfterHeader;

  /// Upper bound on a server-requested `Retry-After` delay.
  ///
  /// Only used when [respectRetryAfterHeader] is `true`. When `null`, the
  /// server-specified delay is used as-is.
  final Duration? maxRetryAfterDelay;

  /// An additional [CancellationToken] whose cancellation also aborts the
  /// retry loop, independently of the per-request context token.
  ///
  /// Useful when a policy is shared across requests and you want a single
  /// kill-switch for all of them.
  final CancellationToken? cancellationToken;

  // -------------------------------------------------------------------------
  // Copy-with
  // -------------------------------------------------------------------------

  /// Returns a copy of this policy with the specified fields replaced.
  ///
  /// ```dart
  /// final policy = RetryPolicy.exponential(maxRetries: 3)
  ///     .copyWith(respectRetryAfterHeader: true);
  /// ```
  RetryPolicy copyWith({
    int? maxRetries,
    DelayProvider? delayProvider,
    RetryPredicate? shouldRetry,
    bool? respectRetryAfterHeader,
    Duration? maxRetryAfterDelay,
    CancellationToken? cancellationToken,
  }) =>
      RetryPolicy._(
        maxRetries: maxRetries ?? this.maxRetries,
        delayProvider: delayProvider ?? this.delayProvider,
        shouldRetry: shouldRetry ?? this.shouldRetry,
        respectRetryAfterHeader:
            respectRetryAfterHeader ?? this.respectRetryAfterHeader,
        maxRetryAfterDelay: maxRetryAfterDelay ?? this.maxRetryAfterDelay,
        cancellationToken: cancellationToken ?? this.cancellationToken,
      );

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  static bool _defaultShouldRetry(
    HttpResponse? response,
    Object? exception,
    HttpContext context,
  ) {
    if (exception != null) return true; // Network errors → always retry
    return response != null && response.isServerError;
  }

  /// Builds a [RetryPredicate] from an [OutcomeClassifier].
  static RetryPredicate _predicateFromClassifier(OutcomeClassifier classifier) =>
      (response, exception, context) {
        if (response != null) {
          return classifier.classifyResponse(response).isRetryable;
        }
        if (exception != null) {
          return classifier.classifyException(exception).isRetryable;
        }
        return false;
      };

  static Duration _noDelay(int _) => Duration.zero;

  static final math.Random _rng = math.Random();

  static double _random() => _rng.nextDouble();
}
