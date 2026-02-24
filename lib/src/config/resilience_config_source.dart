import 'dart:async';

import 'resilience_config.dart';
import 'resilience_config_loader.dart';

/// Abstraction for a source of [ResilienceConfig].
///
/// A *static* source loads a fixed configuration once and has no [changes]
/// stream.  A *dynamic* source emits a new [ResilienceConfig] via [changes]
/// whenever the underlying data changes (e.g. after a file reload or a
/// remote push).
///
/// ## Implementing a custom source
/// ```dart
/// final class MyRemoteConfigSource implements ResilienceConfigSource {
///   @override
///   ResilienceConfig load() {
///     // Load config synchronously (from cache / last-known state).
///     return _cached;
///   }
///
///   @override
///   Stream<ResilienceConfig>? get changes => _stream;
///
///   late final Stream<ResilienceConfig> _stream =
///       _fetchChanges().asBroadcastStream();
/// }
/// ```
abstract interface class ResilienceConfigSource {
  /// Loads the current [ResilienceConfig] synchronously.
  ///
  /// Implementations must not throw; callers assume a valid config is always
  /// available.
  ResilienceConfig load();

  /// A broadcast stream that emits a new [ResilienceConfig] whenever the
  /// configuration changes.
  ///
  /// Returns `null` for static sources where change notifications are not
  /// supported.
  Stream<ResilienceConfig>? get changes;
}

// ---------------------------------------------------------------------------
// Built-in sources
// ---------------------------------------------------------------------------

/// A [ResilienceConfigSource] backed by a raw JSON string.
///
/// This is a **static** source — it parses [`json`] once per [load] call and
/// provides no [changes] stream.
///
/// ```dart
/// const json = '''
/// {
///   "Resilience": {
///     "Retry": { "MaxRetries": 3 },
///     "Timeout": { "Seconds": 10 }
///   }
/// }
/// ''';
/// final source = JsonStringConfigSource(json);
/// final config = source.load();
/// ```
final class JsonStringConfigSource implements ResilienceConfigSource {
  /// Creates a [JsonStringConfigSource] that parses [`json`] on every [load].
  const JsonStringConfigSource(this._json);

  final String _json;
  static const _loader = ResilienceConfigLoader();

  @override
  ResilienceConfig load() => _loader.load(_json);

  @override
  Stream<ResilienceConfig>? get changes => null;
}

/// A [ResilienceConfigSource] backed by an in-memory [ResilienceConfig].
///
/// This is a **dynamic** source: calling [update] replaces the stored config
/// and emits the new value on [changes].
///
/// Typical use cases:
/// - Unit testing config-driven behaviour.
/// - Hot-reloading configuration at runtime without restarting the process.
///
/// ```dart
/// final source = InMemoryConfigSource(ResilienceConfig(
///   retry: RetryConfig(maxRetries: 3),
///   timeout: TimeoutConfig(seconds: 10),
/// ));
///
/// // Later, update the config:
/// source.update(ResilienceConfig(retry: RetryConfig(maxRetries: 5)));
/// ```
///
/// Call [dispose] when the source is no longer needed to release the
/// underlying [StreamController].
final class InMemoryConfigSource implements ResilienceConfigSource {
  /// Creates an [InMemoryConfigSource] with [initial] as the starting config.
  InMemoryConfigSource(ResilienceConfig initial) : _config = initial;

  ResilienceConfig _config;
  final StreamController<ResilienceConfig> _controller =
      StreamController<ResilienceConfig>.broadcast();

  @override
  ResilienceConfig load() => _config;

  @override
  Stream<ResilienceConfig> get changes => _controller.stream;

  /// Replaces the current configuration with [config] and emits the new value
  /// on [changes].
  ///
  /// Throws [StateError] if [dispose] has already been called.
  void update(ResilienceConfig config) {
    _config = config;
    _controller.add(config);
  }

  /// Closes the [changes] stream.
  ///
  /// After calling [dispose], [update] must not be called.
  Future<void> dispose() => _controller.close();
}
