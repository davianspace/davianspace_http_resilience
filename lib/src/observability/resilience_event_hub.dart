import 'dart:async';
import 'dart:collection';

import 'resilience_event.dart';

// ============================================================================
// ResilienceEventListener typedef
// ============================================================================

/// Callback type for typed or global event listeners.
///
/// Listeners may be synchronous (`void`) or asynchronous (`Future<void>`).
/// When async, the returned [Future] is **not awaited** by the hub — the hub
/// schedules listeners fire-and-forget to avoid blocking the emitting policy.
///
/// ```dart
/// // Synchronous
/// hub.on<RetryEvent>((event) => print('Retry ${event.attemptNumber}'));
///
/// // Asynchronous
/// hub.on<FallbackEvent>((event) async {
///   await metricsClient.record('fallback', data: event.toString());
/// });
/// ```
typedef ResilienceEventListener<E extends ResilienceEvent> = FutureOr<void>
    Function(E event);

// ============================================================================
// ResilienceEventHub
// ============================================================================

/// A lightweight, centralized event bus that dispatches resilience lifecycle
/// events to registered listeners without blocking policy execution.
///
/// ## Overview
///
/// [ResilienceEventHub] is the single integration point for **observability**:
/// policies emit structured [ResilienceEvent] instances here; application code
/// registers listeners to react to them.
///
/// ## Registering listeners
///
/// Use [on] to receive only events of a specific type:
///
/// ```dart
/// final hub = ResilienceEventHub();
///
/// hub.on<RetryEvent>((e) {
///   print('Retry attempt ${e.attemptNumber}/${e.maxAttempts} '
///         'after ${e.delay.inMilliseconds}ms');
/// });
///
/// hub.on<CircuitOpenEvent>((e) {
///   alerting.fire('circuit_open', circuit: e.circuitName);
/// });
/// ```
///
/// Use [onAny] to receive **every** event regardless of type:
///
/// ```dart
/// hub.onAny((e) => log.info('[resilience] $e'));
/// ```
///
/// ## Attaching to policies
///
/// Pass the hub via the `eventHub` parameter on the relevant policy or builder:
///
/// ```dart
/// final hub = ResilienceEventHub();
///
/// // Individual policy:
/// final retry = Policy.retry(maxRetries: 3, eventHub: hub);
///
/// // Builder:
/// final pipeline = ResiliencePipelineBuilder()
///     .addRetry(maxRetries: 3, eventHub: hub)
///     .addCircuitBreaker(circuitName: 'svc', eventHub: hub)
///     .addTimeout(const Duration(seconds: 10), eventHub: hub)
///     .build();
/// ```
///
/// You may share one hub across all policies:
///
/// ```dart
/// final hub = ResilienceEventHub(); // one per application
///
/// hub.on<RetryEvent>(...)
///    .on<CircuitOpenEvent>(...);      // fluent registration
/// ```
///
/// ## Performance
///
/// Events are dispatched via [scheduleMicrotask]:
///
/// * The [emit] call itself is **O(1)** — it schedules one microtask.
/// * Listeners run outside the emitting policy's synchronous call stack.
/// * One slow or failing listener cannot stall others: each listener is
///   wrapped in a try/catch; async errors are ignored.
/// * If there are no registered listeners, [emit] is a **no-op** (fast path).
///
/// ## Lifecycle
///
/// Call [clear] to remove all listeners (e.g. in tearDown between tests).
/// Removing individual listeners is supported via [off] and [offAny].
///
/// ## Thread safety
///
/// [ResilienceEventHub] is single-isolate safe. Do not share instances
/// across Dart isolates.
final class ResilienceEventHub {
  /// Creates a [ResilienceEventHub].
  ///
  /// [onListenerError] — optional callback invoked when a listener throws
  /// synchronously or its returned [Future] completes with an error. When
  /// `null` (the default), errors are silently discarded so that a
  /// misbehaving listener cannot disrupt other listeners or the emitting
  /// policy.
  ///
  /// ```dart
  /// final hub = ResilienceEventHub(
  ///   onListenerError: (e, st) => log.severe('Listener error', e, st),
  /// );
  /// ```
  ResilienceEventHub({this.onListenerError, this.maxListeners = 100});

  /// Called when a listener throws or its [Future] completes with an error.
  ///
  /// `null` by default — errors are silently swallowed.
  final void Function(Object error, StackTrace st)? onListenerError;

  /// Maximum number of total listeners before a warning is emitted via
  /// [onListenerError].
  ///
  /// This is a diagnostic guard to detect listener leaks in long-running apps.
  /// Set to `0` to disable the check.
  final int maxListeners;

  // Typed listeners stored under their exact runtime Type key.
  final _typedListeners = HashMap<Type, List<Function>>();

  // Global listeners invoked for every event.
  final _anyListeners = <ResilienceEventListener<ResilienceEvent>>[];

  /// The total number of registered listeners (typed + global).
  int get listenerCount {
    var count = _anyListeners.length;
    for (final list in _typedListeners.values) {
      count += list.length;
    }
    return count;
  }

  void _checkMaxListeners() {
    if (maxListeners > 0 && listenerCount > maxListeners) {
      final handler = onListenerError;
      if (handler != null) {
        handler(
          StateError(
            'ResilienceEventHub: $listenerCount listeners registered, '
            'exceeding maxListeners=$maxListeners. '
            'Possible listener leak — ensure off()/offAny() is called.',
          ),
          StackTrace.current,
        );
      }
    }
  }

  // --------------------------------------------------------------------------
  // Typed subscription
  // --------------------------------------------------------------------------

  /// Registers [listener] to be called for every event of type [E].
  ///
  /// Multiple distinct listeners may be registered for the same type.
  /// Registering the same listener instance more than once is idempotent:
  /// the listener will only be invoked once per event.
  ///
  /// Returns `this` for fluent chaining:
  /// ```dart
  /// hub
  ///   .on<RetryEvent>((e) => logRetry(e))
  ///   .on<CircuitOpenEvent>((e) => alertCircuit(e));
  /// ```
  ResilienceEventHub on<E extends ResilienceEvent>(
    ResilienceEventListener<E> listener,
  ) {
    final list = _typedListeners.putIfAbsent(E, () => []);
    if (!list.contains(listener)) {
      list.add(listener);
      _checkMaxListeners();
    }
    return this;
  }

  /// Removes a previously registered typed [listener] for type [E].
  ///
  /// Only the first matching entry is removed. A no-op if [listener] is not
  /// registered.
  ResilienceEventHub off<E extends ResilienceEvent>(
    ResilienceEventListener<E> listener,
  ) {
    final list = _typedListeners[E];
    if (list != null) {
      list.remove(listener);
      if (list.isEmpty) _typedListeners.remove(E);
    }
    return this;
  }

  // --------------------------------------------------------------------------
  // Global subscription
  // --------------------------------------------------------------------------

  /// Registers [listener] to be called for **every** event regardless of type.
  ///
  /// Use pattern-matching on the [ResilienceEvent] sealed class to distinguish
  /// event types:
  ///
  /// ```dart
  /// hub.onAny((event) => switch (event) {
  ///   RetryEvent e        => recordRetry(e),
  ///   CircuitOpenEvent e  => sendAlert(e),
  ///   _                   => null,
  /// });
  /// ```
  ///
  /// Returns `this` for fluent chaining.
  ResilienceEventHub onAny(
    ResilienceEventListener<ResilienceEvent> listener,
  ) {
    if (!_anyListeners.contains(listener)) {
      _anyListeners.add(listener);
      _checkMaxListeners();
    }
    return this;
  }

  /// Removes a previously registered global [listener].
  ///
  /// A no-op if [listener] is not registered.
  ResilienceEventHub offAny(
    ResilienceEventListener<ResilienceEvent> listener,
  ) {
    _anyListeners.remove(listener);
    return this;
  }

  // --------------------------------------------------------------------------
  // Introspection
  // --------------------------------------------------------------------------

  /// Returns `true` when no listeners are registered on this hub.
  bool get isEmpty => _typedListeners.isEmpty && _anyListeners.isEmpty;

  /// Returns `true` when at least one listener is registered.
  bool get isNotEmpty => !isEmpty;

  /// Removes all typed and global listeners, resetting the hub to an empty
  /// state.
  ///
  /// Useful between tests or during application teardown.
  void clear() {
    _typedListeners.clear();
    _anyListeners.clear();
  }

  // --------------------------------------------------------------------------
  // Emission (internal — called by policies)
  // --------------------------------------------------------------------------

  /// Dispatches [event] to all matching listeners asynchronously via
  /// [scheduleMicrotask].
  ///
  /// **This method returns immediately** — it never blocks the calling policy.
  /// Listeners run in the microtask queue after the current synchronous frame
  /// completes.
  ///
  /// Errors thrown by synchronous listeners and futures returned by async
  /// listeners are silently discarded: they must not propagate back to the
  /// emitting policy.
  void emit(ResilienceEvent event) {
    // Fast path: nothing to do.
    if (_typedListeners.isEmpty && _anyListeners.isEmpty) return;

    // Snapshot both listener lists to guard against mutation during iteration.
    final typed = _typedListeners[event.runtimeType];
    final typedSnapshot =
        typed != null ? List<Function>.of(typed) : const <Function>[];
    final anySnapshot =
        List<ResilienceEventListener<ResilienceEvent>>.of(_anyListeners);

    if (typedSnapshot.isEmpty && anySnapshot.isEmpty) return;

    final errorHandler = onListenerError;
    scheduleMicrotask(() {
      for (final listener in typedSnapshot) {
        _safeInvoke(listener, event, errorHandler);
      }
      for (final listener in anySnapshot) {
        _safeInvoke(listener, event, errorHandler);
      }
    });
  }

  // --------------------------------------------------------------------------
  // Internal helpers
  // --------------------------------------------------------------------------

  static void _safeInvoke(
    Function listener,
    ResilienceEvent event,
    void Function(Object, StackTrace)? onError,
  ) {
    try {
      // ignore: avoid_dynamic_calls
      final result = listener(event);
      if (result is Future<void>) {
        if (onError != null) {
          result.catchError(
            (Object e, StackTrace st) => onError(e, st),
          );
        } else {
          result.ignore();
        }
      }
    } on Object catch (e, st) {
      if (onError != null) {
        onError(e, st);
      }
      // else swallow so other listeners still run and the emitting policy
      // is not disrupted.
    }
  }

  @override
  String toString() {
    final typedCount =
        _typedListeners.values.fold(0, (sum, list) => sum + list.length);
    return 'ResilienceEventHub('
        'typedListeners=$typedCount, '
        'anyListeners=${_anyListeners.length})';
  }
}
