import 'dart:convert';

import 'resilience_config.dart';

/// Parses [ResilienceConfig] from JSON.
///
/// The expected JSON structure follows the .NET `appsettings.json` convention:
///
/// ```json
/// {
///   "Resilience": {
///     "Retry": {
///       "MaxRetries": 3,
///       "RetryForever": false,
///       "Backoff": {
///         "Type": "exponential",
///         "BaseMs": 200,
///         "MaxDelayMs": 30000,
///         "UseJitter": true
///       }
///     },
///     "Timeout": { "Seconds": 10 },
///     "CircuitBreaker": {
///       "CircuitName": "api",
///       "FailureThreshold": 5,
///       "SuccessThreshold": 1,
///       "BreakSeconds": 30
///     },
///     "Bulkhead": {
///       "MaxConcurrency": 20,
///       "MaxQueueDepth": 100,
///       "QueueTimeoutSeconds": 10
///     },
///     "BulkheadIsolation": {
///       "MaxConcurrentRequests": 10,
///       "MaxQueueSize": 100,
///       "QueueTimeoutSeconds": 10
///     }
///   }
/// }
/// ```
///
/// All fields are optional; missing fields fall back to their default values.
/// The top-level `"Resilience"` wrapper is optional — you can also call
/// [loadMap] directly with the inner map.
///
/// ## Accepted `Backoff.Type` values (case-insensitive)
/// | JSON value                | [BackoffType]                    |
/// |---------------------------|----------------------------------|
/// | `"none"` / `""`           | [BackoffType.none]               |
/// | `"constant"`              | [BackoffType.constant]           |
/// | `"linear"`                | [BackoffType.linear]             |
/// | `"exponential"`           | [BackoffType.exponential]        |
/// | `"decorrelatedjitter"`, `"decorrelated_jitter"`, `"decorrelated-jitter"` | [BackoffType.decorrelatedJitter] |
///
/// ## Usage
/// ```dart
/// const loader = ResilienceConfigLoader();
/// final config = loader.load(jsonString);
/// ```
final class ResilienceConfigLoader {
  /// Creates a [ResilienceConfigLoader].
  const ResilienceConfigLoader();

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  /// Parses [json] and returns the contained [ResilienceConfig].
  ///
  /// Expects a JSON object at the root.  The resilience configuration may be
  /// nested under a `"Resilience"` key or provided directly as the root
  /// object:
  ///
  /// ```dart
  /// // With wrapper
  /// loader.load('{"Resilience": {"Retry": {"MaxRetries": 3}}}');
  ///
  /// // Without wrapper (same result)
  /// loader.load('{"Retry": {"MaxRetries": 3}}');
  /// ```
  ///
  /// Throws [FormatException] if [json] is not valid JSON or if a field has
  /// an unexpected type.
  ResilienceConfig load(String json) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Expected a JSON object at the root.',
      );
    }

    // Support both `{"Resilience": {...}}` and `{...}` directly.
    final dynamic resilience = decoded['Resilience'];
    if (resilience == null) {
      // No "Resilience" key — treat the whole object as the resilience section.
      return loadMap(decoded);
    }
    if (resilience is! Map<String, dynamic>) {
      throw const FormatException(
        '"Resilience" must be a JSON object.',
      );
    }
    return loadMap(resilience);
  }

  /// Parses a pre-decoded [map] and returns a [ResilienceConfig].
  ///
  /// Useful when the resilience section has already been extracted from a
  /// larger configuration tree.
  ///
  /// Throws [FormatException] if any field has an unexpected type.
  ResilienceConfig loadMap(Map<String, dynamic> map) {
    return ResilienceConfig(
      retry: _parseRetry(map),
      timeout: _parseTimeout(map),
      circuitBreaker: _parseCircuitBreaker(map),
      bulkhead: _parseBulkhead(map),
      bulkheadIsolation: _parseBulkheadIsolation(map),
    );
  }

  // --------------------------------------------------------------------------
  // Section parsers
  // --------------------------------------------------------------------------

  RetryConfig? _parseRetry(Map<String, dynamic> map) {
    final dynamic raw = map['Retry'];
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('"Retry" must be a JSON object.');
    }
    return RetryConfig(
      maxRetries: _int(raw, 'MaxRetries', 3),
      retryForever: _bool(raw, 'RetryForever', false),
      backoff: _parseBackoff(raw['Backoff']),
    );
  }

  TimeoutConfig? _parseTimeout(Map<String, dynamic> map) {
    final dynamic raw = map['Timeout'];
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('"Timeout" must be a JSON object.');
    }
    return TimeoutConfig(seconds: _int(raw, 'Seconds', 30));
  }

  CircuitBreakerConfig? _parseCircuitBreaker(Map<String, dynamic> map) {
    final dynamic raw = map['CircuitBreaker'];
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('"CircuitBreaker" must be a JSON object.');
    }
    return CircuitBreakerConfig(
      circuitName: _string(raw, 'CircuitName', 'default'),
      failureThreshold: _int(raw, 'FailureThreshold', 5),
      successThreshold: _int(raw, 'SuccessThreshold', 1),
      breakSeconds: _int(raw, 'BreakSeconds', 30),
    );
  }

  BulkheadConfig? _parseBulkhead(Map<String, dynamic> map) {
    final dynamic raw = map['Bulkhead'];
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('"Bulkhead" must be a JSON object.');
    }
    return BulkheadConfig(
      maxConcurrency: _int(raw, 'MaxConcurrency', 10),
      maxQueueDepth: _int(raw, 'MaxQueueDepth', 100),
      queueTimeoutSeconds: _int(raw, 'QueueTimeoutSeconds', 10),
    );
  }

  BulkheadIsolationConfig? _parseBulkheadIsolation(Map<String, dynamic> map) {
    final dynamic raw = map['BulkheadIsolation'];
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('"BulkheadIsolation" must be a JSON object.');
    }
    return BulkheadIsolationConfig(
      maxConcurrentRequests: _int(raw, 'MaxConcurrentRequests', 10),
      maxQueueSize: _int(raw, 'MaxQueueSize', 100),
      queueTimeoutSeconds: _int(raw, 'QueueTimeoutSeconds', 10),
    );
  }

  BackoffConfig? _parseBackoff(dynamic raw) {
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('"Backoff" must be a JSON object.');
    }
    final typeStr = _string(raw, 'Type', 'none').toLowerCase().replaceAll(
          RegExp(r'[-_]'),
          '',
        );
    final type = switch (typeStr) {
      'constant' => BackoffType.constant,
      'linear' => BackoffType.linear,
      'exponential' => BackoffType.exponential,
      'decorrelatedjitter' => BackoffType.decorrelatedJitter,
      '' => BackoffType.none,
      'none' => BackoffType.none,
      _ => throw FormatException(
            'Unknown backoff type "${_string(raw, 'Type', 'none')}". '
            'Expected one of: none, constant, linear, exponential, '
            'decorrelatedJitter.',
          ),
    };
    final dynamic rawMaxDelayMs = raw['MaxDelayMs'];
    final int? maxDelayMs = switch (rawMaxDelayMs) {
      final int v => v,
      final num v => v.toInt(),
      null => null,
      _ => throw FormatException(
          '"MaxDelayMs" must be an integer, got ${rawMaxDelayMs.runtimeType}.',
        ),
    };
    return BackoffConfig(
      type: type,
      baseMs: _int(raw, 'BaseMs', 200),
      maxDelayMs: maxDelayMs,
      useJitter: _bool(raw, 'UseJitter', false),
    );
  }

  // --------------------------------------------------------------------------
  // Field helpers
  // --------------------------------------------------------------------------

  int _int(Map<String, dynamic> map, String key, int defaultValue) {
    final dynamic v = map[key];
    return switch (v) {
      null => defaultValue,
      final int i => i,
      final num n => n.toInt(),
      _ => throw FormatException(
          '"$key" must be an integer, got ${v.runtimeType}.',
        ),
    };
  }

  bool _bool(Map<String, dynamic> map, String key, bool defaultValue) {
    final dynamic v = map[key];
    return switch (v) {
      null => defaultValue,
      final bool b => b,
      _ => throw FormatException(
          '"$key" must be a boolean, got ${v.runtimeType}.',
        ),
    };
  }

  String _string(Map<String, dynamic> map, String key, String defaultValue) {
    final dynamic v = map[key];
    return switch (v) {
      null => defaultValue,
      final String s => s,
      _ => throw FormatException(
          '"$key" must be a string, got ${v.runtimeType}.',
        ),
    };
  }
}
