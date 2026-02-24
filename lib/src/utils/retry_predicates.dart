import 'package:http/http.dart' as http;

import '../policies/retry_policy.dart';

/// Pre-built [RetryPredicate] factories for common retry scenarios.
///
/// Compose these with `&&`/`||` logic inside a custom predicate:
/// ```dart
/// final policy = RetryPolicy.exponential(
///   maxRetries: 3,
///   shouldRetry: RetryPredicates.serverErrors
///     .or(RetryPredicates.networkErrors),
/// );
/// ```
abstract final class RetryPredicates {
  RetryPredicates._();

  /// Retries on any 5xx server error.
  static RetryPredicate get serverErrors =>
      (response, _, __) => response != null && response.isServerError;

  /// Retries on connection-level failures surfaced by `package:http` as
  /// [http.ClientException] (covers TCP/TLS errors, DNS failures, and
  /// connection resets on both native and web platforms).
  ///
  /// Use [anyException] instead if you want to retry on *any* thrown
  /// exception regardless of type.
  static RetryPredicate get networkErrors =>
      (response, exception, __) => exception is http.ClientException;

  /// Retries whenever an exception of any type is thrown.
  ///
  /// This is the broadest predicate: it fires on [http.ClientException],
  /// application-level exceptions, and anything else.  Prefer [networkErrors]
  /// or [serverErrors] for more precise control.
  static RetryPredicate get anyException =>
      (response, exception, __) => exception != null;

  /// Retries on 429 (Too Many Requests) and 503 (Service Unavailable).
  static RetryPredicate get rateLimitAndServiceUnavailable =>
      (response, _, __) =>
          response != null &&
          (response.statusCode == 429 || response.statusCode == 503);

  /// Retries on any non-2xx response.
  static RetryPredicate get nonSuccess =>
      (response, _, __) => response != null && !response.isSuccess;

  /// Combines two predicates with logical OR.
  ///
  /// Example:
  /// ```dart
  /// final predicate = RetryPredicates.serverErrors
  ///     .or(RetryPredicates.rateLimitAndServiceUnavailable);
  /// ```
  static RetryPredicate combine(
    RetryPredicate a,
    RetryPredicate b, {
    bool useOr = true,
  }) =>
      (response, exception, context) => useOr
          ? a(response, exception, context) || b(response, exception, context)
          : a(response, exception, context) && b(response, exception, context);
}

/// Extension on [RetryPredicate] for fluent combinators.
extension RetryPredicateExtensions on RetryPredicate {
  /// Returns a new predicate that is `true` when `this` OR [other] is `true`.
  RetryPredicate or(RetryPredicate other) => RetryPredicates.combine(
        this,
        other,
      );

  /// Returns a new predicate that is `true` when `this` AND [other] are both
  /// `true`.
  RetryPredicate and(RetryPredicate other) =>
      RetryPredicates.combine(this, other, useOr: false);
}
