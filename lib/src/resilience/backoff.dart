import 'dart:math' as math;

/// Strategy that computes the delay to apply before a retry attempt.
///
/// Attempt numbers are **1-based**: attempt 1 is the first retry,
/// attempt 2 is the second, and so on.
///
/// Implement this interface to provide a custom back-off strategy:
/// ```dart
/// final class FibonacciBackoff implements RetryBackoff {
///   const FibonacciBackoff(this.unit);
///   final Duration unit;
///   @override
///   Duration delayFor(int attempt) {
///     int a = 0, b = 1;
///     for (var i = 0; i < attempt; i++) { final t = a + b; a = b; b = t; }
///     return unit * a;
///   }
/// }
/// ```
abstract interface class RetryBackoff {
  /// Returns the delay duration to wait before retry [attempt] (1-based).
  Duration delayFor(int attempt);
}

// ---------------------------------------------------------------------------
// Built-in strategies
// ---------------------------------------------------------------------------

/// Zero delay — retries immediately without any waiting.
///
/// Only appropriate for local/in-process operations where no actual I/O
/// back-pressure is expected.
final class NoBackoff implements RetryBackoff {
  const NoBackoff();

  @override
  Duration delayFor(int attempt) => Duration.zero;

  @override
  String toString() => 'NoBackoff';
}

/// Fixed delay between every retry attempt.
///
/// ```dart
/// const backoff = ConstantBackoff(Duration(milliseconds: 500));
/// backoff.delayFor(1); // → 500 ms
/// backoff.delayFor(3); // → 500 ms  (always the same)
/// ```
final class ConstantBackoff implements RetryBackoff {
  const ConstantBackoff(this.delay);

  /// The fixed delay applied before every retry.
  final Duration delay;

  @override
  Duration delayFor(int attempt) => delay;

  @override
  String toString() => 'ConstantBackoff(${delay.inMilliseconds}ms)';
}

/// Linearly increasing delay: `base × attempt`.
///
/// ```dart
/// const backoff = LinearBackoff(Duration(milliseconds: 100));
/// backoff.delayFor(1); // → 100 ms
/// backoff.delayFor(2); // → 200 ms
/// backoff.delayFor(3); // → 300 ms
/// ```
final class LinearBackoff implements RetryBackoff {
  const LinearBackoff(this.base);

  /// The base duration multiplied by the attempt number.
  final Duration base;

  @override
  Duration delayFor(int attempt) => base * attempt;

  @override
  String toString() => 'LinearBackoff(base=${base.inMilliseconds}ms)';
}

/// Exponential back-off: `base × 2^(attempt−1)`, capped at [maxDelay].
///
/// When [useJitter] is `true`, the full-jitter strategy is applied:
/// the actual delay is a random value in `[0, cappedDelay]`.  This
/// avoids the *thundering-herd* problem when many clients retry simultaneously.
///
/// ```dart
/// const backoff = ExponentialBackoff(
///   Duration(milliseconds: 100),
///   maxDelay: Duration(seconds: 5),
///   useJitter: true,
/// );
/// backoff.delayFor(1); // → 0–100 ms (jittered)
/// backoff.delayFor(2); // → 0–200 ms (jittered)
/// backoff.delayFor(3); // → 0–400 ms (jittered)
/// ```
final class ExponentialBackoff implements RetryBackoff {
  const ExponentialBackoff(
    this.base, {
    this.maxDelay = const Duration(seconds: 30),
    this.useJitter = false,
    this.random,
  });

  /// Starting duration.  Subsequent delays double each attempt.
  final Duration base;

  /// Hard ceiling applied after the exponential calculation.
  final Duration maxDelay;

  /// When `true` applies full-jitter for thundering-herd avoidance.
  final bool useJitter;

  /// Optional seeded [math.Random] for deterministic tests.
  final math.Random? random;

  @override
  Duration delayFor(int attempt) {
    final expMs = (base.inMilliseconds * math.pow(2, attempt - 1)).round();
    final cappedMs = expMs.clamp(0, maxDelay.inMilliseconds);
    if (!useJitter) return Duration(milliseconds: cappedMs);
    // Full-jitter: uniformly pick from [0, cappedDelay)
    final jitterMs =
        ((random ?? math.Random()).nextDouble() * cappedMs).round();
    return Duration(milliseconds: jitterMs);
  }

  @override
  String toString() => 'ExponentialBackoff(base=${base.inMilliseconds}ms, '
      'maxDelay=${maxDelay.inMilliseconds}ms, useJitter=$useJitter)';
}

/// Decorator that adds full-jitter on top of any underlying strategy.
///
/// Useful when you want jitter on top of, e.g., [LinearBackoff]:
/// ```dart
/// final backoff = JitteredBackoff(LinearBackoff(Duration(milliseconds: 100)));
/// ```
final class JitteredBackoff implements RetryBackoff {
  JitteredBackoff(this._inner, {math.Random? random}) : _random = random;

  final RetryBackoff _inner;
  final math.Random? _random;

  @override
  Duration delayFor(int attempt) {
    final base = _inner.delayFor(attempt);
    final fraction = (_random ?? math.Random()).nextDouble();
    return Duration(milliseconds: (base.inMilliseconds * fraction).round());
  }

  @override
  String toString() => 'JitteredBackoff($_inner)';
}

/// Wraps another strategy and clamps its output to [maxDelay].
final class CappedBackoff implements RetryBackoff {
  const CappedBackoff(this._inner, this.maxDelay);

  final RetryBackoff _inner;

  /// The maximum delay ever returned by [delayFor].
  final Duration maxDelay;

  @override
  Duration delayFor(int attempt) {
    final d = _inner.delayFor(attempt);
    return d > maxDelay ? maxDelay : d;
  }

  @override
  String toString() =>
      'CappedBackoff($_inner, max=${maxDelay.inMilliseconds}ms)';
}

/// Delegate-based strategy for one-off or lambda-style back-offs.
///
/// ```dart
/// final backoff = CustomBackoff((attempt) => Duration(seconds: attempt * attempt));
/// ```
final class CustomBackoff implements RetryBackoff {
  const CustomBackoff(this._fn);

  final Duration Function(int attempt) _fn;

  @override
  Duration delayFor(int attempt) => _fn(attempt);

  @override
  String toString() => 'CustomBackoff';
}

// ---------------------------------------------------------------------------
// Jitter-focused strategies
// ---------------------------------------------------------------------------

/// Stateless approximation of the AWS-recommended **decorrelated jitter**
/// back-off strategy.
///
/// Each delay is drawn uniformly at random from the interval
/// `[base, min(maxDelay, base × 3^(attempt–1))]`:
///
/// | attempt | lower  | upper (base=200ms, cap=30s) |
/// |---------|--------|-----------------------------|
/// | 1       | 200 ms | 200 ms (base)                |
/// | 2       | 200 ms | 600 ms                       |
/// | 3       | 200 ms | 1 800 ms                     |
/// | 4       | 200 ms | 5 400 ms                     |
/// | 5+      | 200 ms | 30 000 ms (capped)           |
///
/// This produces highly varied delays that break synchronised retry waves
/// much more aggressively than full-jitter exponential back-off.
///
/// > **Note:** This class is **stateless** and therefore safe to share across
/// > concurrent retry executions.  The AWS algorithm is stateful (depends on
/// > the previous delay); this is a thread-safe approximation that gives
/// > the same statistical behaviour in aggregate.
///
/// ```dart
/// const backoff = DecorrelatedJitterBackoff(
///   Duration(milliseconds: 200),
///   maxDelay: Duration(seconds: 30),
/// );
/// backoff.delayFor(1);  // 200 ms  (floor == cap at attempt 1)
/// backoff.delayFor(4);  // ≈200–5400 ms random
/// ```
final class DecorrelatedJitterBackoff implements RetryBackoff {
  const DecorrelatedJitterBackoff(
    this.base, {
    this.maxDelay = const Duration(seconds: 30),
    this.random,
  }) : assert(
          base > Duration.zero,
          'base must be positive',
        );

  /// Minimum delay and the starting base for the exponential range.
  final Duration base;

  /// Hard ceiling on the computed delay.
  final Duration maxDelay;

  /// Optional seeded [math.Random] for deterministic tests.
  final math.Random? random;

  @override
  Duration delayFor(int attempt) {
    if (attempt <= 0) return Duration.zero;
    // Upper bound = min(maxDelay, base × 3^(attempt-1)).
    final multiplier = math.pow(3, attempt - 1);
    final upperMs = (base.inMilliseconds * multiplier)
        .round()
        .clamp(0, maxDelay.inMilliseconds);
    final lowerMs = base.inMilliseconds.clamp(0, upperMs);
    if (lowerMs >= upperMs) return Duration(milliseconds: lowerMs);
    final rng = random ?? math.Random();
    return Duration(
      milliseconds: lowerMs + rng.nextInt(upperMs - lowerMs + 1),
    );
  }

  @override
  String toString() => 'DecorrelatedJitterBackoff('
      'base=${base.inMilliseconds}ms, '
      'maxDelay=${maxDelay.inMilliseconds}ms)';
}

/// Adds a uniform random jitter in `[0, jitterRange]` on top of any base
/// back-off strategy.
///
/// Use this when you want a deterministic base delay *plus* a small random
/// spread to avoid synchronised retries:
///
/// ```dart
/// // Constant 500 ms + up to 200 ms random spread
/// final backoff = AddedJitterBackoff(
///   ConstantBackoff(Duration(milliseconds: 500)),
///   jitterRange: Duration(milliseconds: 200),
/// );
/// backoff.delayFor(1);  // 500–700 ms
/// backoff.delayFor(5);  // 500–700 ms
/// ```
///
/// To apply jitter proportional to the base delay, use [JitteredBackoff]
/// instead.
final class AddedJitterBackoff implements RetryBackoff {
  const AddedJitterBackoff(
    this._inner, {
    required this.jitterRange,
    this.random,
  });

  final RetryBackoff _inner;

  /// Maximum extra duration added to the base delay.
  final Duration jitterRange;

  /// Optional seeded [math.Random] for deterministic tests.
  final math.Random? random;

  @override
  Duration delayFor(int attempt) {
    final base = _inner.delayFor(attempt);
    if (jitterRange <= Duration.zero) return base;
    final jitterMs =
        ((random ?? math.Random()).nextDouble() * jitterRange.inMilliseconds)
            .round();
    return base + Duration(milliseconds: jitterMs);
  }

  @override
  String toString() => 'AddedJitterBackoff($_inner, '
      'jitterRange=${jitterRange.inMilliseconds}ms)';
}
