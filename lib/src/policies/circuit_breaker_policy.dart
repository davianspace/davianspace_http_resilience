import '../core/http_response.dart';

// ---------------------------------------------------------------------------
// Circuit-breaker state
// ---------------------------------------------------------------------------

/// The three canonical states of a circuit breaker.
enum CircuitState {
  /// The circuit is healthy; requests pass through.
  closed,

  /// The failure threshold has been exceeded; requests are immediately rejected.
  open,

  /// Cool-down elapsed; one probe request is permitted to test the service.
  halfOpen,
}

// ---------------------------------------------------------------------------
// Window mode
// ---------------------------------------------------------------------------

/// Determines how the circuit breaker counts failures before opening.
enum CircuitBreakerWindowMode {
  /// Count consecutive failures since the last success (default).
  ///
  /// The circuit opens after [CircuitBreakerPolicy.failureThreshold]
  /// consecutive failures; a single success resets the streak.
  consecutive,

  /// Count failures within a fixed-size sliding window of recent calls.
  ///
  /// The circuit opens when the number of failures in the last
  /// [CircuitBreakerPolicy.windowSize] calls reaches
  /// [CircuitBreakerPolicy.failureThreshold].
  slidingWindow,
}

// ---------------------------------------------------------------------------
// Policy configuration (immutable)
// ---------------------------------------------------------------------------

/// Immutable configuration for the circuit-breaker policy.
///
/// The circuit transitions to [CircuitState.open] when [failureThreshold]
/// consecutive failures are recorded. After [breakDuration] the circuit
/// moves to [CircuitState.halfOpen] and permits one probe request.
///
/// ```dart
/// final policy = CircuitBreakerPolicy(
///   circuitName: 'payments-api',
///   failureThreshold: 5,
///   breakDuration: Duration(seconds: 30),
/// );
/// ```
final class CircuitBreakerPolicy {
  const CircuitBreakerPolicy({
    this.circuitName = 'default',
    this.failureThreshold = 5,
    this.successThreshold = 1,
    this.breakDuration = const Duration(seconds: 30),
    this.windowMode = CircuitBreakerWindowMode.consecutive,
    this.windowSize = 10,
    CircuitBreakerPredicate? shouldCount,
  }) : _shouldCount = shouldCount;

  /// Logical name for this circuit, used in diagnostics and exceptions.
  final String circuitName;

  /// Number of consecutive failures (or failures within [windowSize] calls
  /// in sliding-window mode) needed to open the circuit.
  final int failureThreshold;

  /// Consecutive successes in Half-Open state required to close the circuit.
  final int successThreshold;

  /// How long the circuit stays open before transitioning to Half-Open.
  final Duration breakDuration;

  /// Whether to use consecutive-failure counting or a sliding window.
  ///
  /// Defaults to [CircuitBreakerWindowMode.consecutive] — existing behaviour
  /// is completely unchanged when this field is not specified.
  final CircuitBreakerWindowMode windowMode;

  /// Number of most-recent calls considered when [windowMode] is
  /// [CircuitBreakerWindowMode.slidingWindow].
  ///
  /// Ignored in [CircuitBreakerWindowMode.consecutive] mode.
  final int windowSize;

  final CircuitBreakerPredicate? _shouldCount;

  /// Returns [`true`] when [response] or [exception] should increment the
  /// failure counter.  Defaults to counting 5xx responses and exceptions.
  bool shouldCount(HttpResponse? response, Object? exception) {
    final callback = _shouldCount;
    if (callback != null) return callback(response, exception);
    if (exception != null) return true;
    return response != null && response.isServerError;
  }
}

/// Signature used to customise which outcomes increment the failure counter.
typedef CircuitBreakerPredicate = bool Function(
  HttpResponse? response,
  Object? exception,
);

// ---------------------------------------------------------------------------
// State-change callback
// ---------------------------------------------------------------------------

/// Called whenever the circuit transitions from one [CircuitState] to another.
///
/// [from] is the previous state; [to] is the new state.
typedef CircuitStateChangeCallback = void Function(
  CircuitState from,
  CircuitState to,
);

// ---------------------------------------------------------------------------
// Metrics snapshot
// ---------------------------------------------------------------------------

/// An immutable snapshot of a circuit breaker's runtime metrics.
///
/// Obtain a snapshot via [CircuitBreakerState.metrics].
///
/// ```dart
/// final m = policy.metrics;
/// print('total: ${m.totalCalls}, failed: ${m.failedCalls}, rejected: ${m.rejectedCalls}');
/// ```
final class CircuitBreakerMetrics {
  /// Creates a [CircuitBreakerMetrics] snapshot.
  const CircuitBreakerMetrics({
    required this.totalCalls,
    required this.successfulCalls,
    required this.failedCalls,
    required this.rejectedCalls,
    required this.consecutiveFailures,
    required this.consecutiveSuccesses,
    required this.lastTransitionAt,
  });

  /// Total calls that were forwarded to the protected action (not rejected).
  final int totalCalls;

  /// Calls whose result did **not** count as a failure.
  final int successfulCalls;

  /// Calls whose result incremented the failure counter.
  final int failedCalls;

  /// Calls rejected outright because the circuit was open (or the half-open
  /// probe slot was already taken).
  final int rejectedCalls;

  /// Consecutive failures since the last success or circuit reset.
  final int consecutiveFailures;

  /// Consecutive successes recorded while the circuit is in Half-Open state.
  final int consecutiveSuccesses;

  /// When the most recent state transition occurred.
  ///
  /// `null` if the circuit has never transitioned.
  final DateTime? lastTransitionAt;

  @override
  String toString() => 'CircuitBreakerMetrics('
      'total=$totalCalls, '
      'ok=$successfulCalls, '
      'failed=$failedCalls, '
      'rejected=$rejectedCalls, '
      'consec_failures=$consecutiveFailures, '
      'consec_successes=$consecutiveSuccesses)';
}

// ---------------------------------------------------------------------------
// Subscription handle for state-change listeners
// ---------------------------------------------------------------------------

/// An opaque handle returned by [CircuitBreakerState.addStateChangeListener].
///
/// Call [cancel] to remove the listener and prevent further invocations.
///
/// ```dart
/// final sub = state.addStateChangeListener((from, to) { ... });
/// // later — avoids holding a permanent reference:
/// sub.cancel();
/// ```
abstract final class Subscription {
  /// Removes the associated listener from the circuit-breaker state.
  void cancel();
}

final class _ListenerSubscription implements Subscription {
  _ListenerSubscription(this._callback, this._list);

  final CircuitStateChangeCallback _callback;
  final List<CircuitStateChangeCallback> _list;

  @override
  void cancel() => _list.remove(_callback);
}

// ---------------------------------------------------------------------------
// Mutable circuit state (one instance per named circuit)
// ---------------------------------------------------------------------------

/// Thread-observable (but single-isolate) state machine for a circuit breaker.
///
/// [CircuitBreakerState] is a long-lived object managed by the
/// [CircuitBreakerRegistry]. Do **not** instantiate it directly unless
/// building a custom registry.
///
/// ### Callbacks
/// Register state-change listeners with [addStateChangeListener]:
/// ```dart
/// state.addStateChangeListener((from, to) {
///   print('Circuit transitioned $from → $to');
/// });
/// ```
///
/// ### Metrics
/// Read a point-in-time metrics snapshot via [metrics].
final class CircuitBreakerState {
  CircuitBreakerState({required this.policy});

  /// The policy that governs state-transition rules for this circuit.
  final CircuitBreakerPolicy policy;

  CircuitState _state = CircuitState.closed;
  int _failureCount = 0;
  int _successCount = 0;
  DateTime? _openedAt;

  // Metrics counters ─────────────────────────────────────────────────────────
  int _totalCalls = 0;
  int _successfulCalls = 0;
  int _failedCalls = 0;
  int _rejectedCalls = 0;
  DateTime? _lastTransitionAt;

  // Callback list ────────────────────────────────────────────────────────────
  final List<CircuitStateChangeCallback> _listeners = [];

  // Half-open concurrency guard ──────────────────────────────────────────────
  /// `true` while a half-open probe request is in flight.
  ///
  /// Ensures only one probe is admitted at a time; subsequent concurrent
  /// requests are rejected with [`CircuitOpenException`] until the probe
  /// completes (and the circuit re-opens or closes).
  bool _halfOpenSlotTaken = false;

  // Sliding-window buffer ────────────────────────────────────────────────────
  // Only populated when policy.windowMode == slidingWindow.
  final List<bool> _window = []; // true = success, false = failure
  int _windowFailures = 0;

  /// Current state of the circuit.
  CircuitState get state => _effectiveState;

  CircuitState get _effectiveState {
    if (_state == CircuitState.open) {
      final opened = _openedAt;
      if (opened != null &&
          DateTime.now().difference(opened) >= policy.breakDuration) {
        // Lazily transition open → halfOpen on the first access after the
        // break duration has elapsed.  No background timer is required.
        _state = CircuitState.halfOpen;
        _successCount = 0;
        _halfOpenSlotTaken = false;
        _lastTransitionAt = DateTime.now();
        _fireStateChange(CircuitState.open, CircuitState.halfOpen);
      }
    }
    return _state;
  }

  /// `true` when the circuit will allow a request through.
  ///
  /// In [CircuitState.halfOpen], only the **first** concurrent caller receives
  /// `true`; subsequent callers are blocked until the probe completes.  This
  /// prevents multiple probes from firing simultaneously.
  bool get isAllowing {
    final st = _effectiveState;
    if (st == CircuitState.closed) return true;
    if (st == CircuitState.halfOpen) {
      if (_halfOpenSlotTaken) return false;
      _halfOpenSlotTaken = true; // claim the probe slot
      return true;
    }
    return false;
  }

  /// Records a successful outcome.
  void recordSuccess() {
    _totalCalls++;
    _successfulCalls++;
    switch (_effectiveState) {
      case CircuitState.halfOpen:
        _successCount++;
        if (_successCount >= policy.successThreshold) _close();
      case CircuitState.closed:
        if (policy.windowMode == CircuitBreakerWindowMode.slidingWindow) {
          _pushWindow(true);
        } else {
          _failureCount = 0; // reset consecutive-failure streak
        }
      case CircuitState.open:
        break;
    }
  }

  /// Records a failed outcome.
  void recordFailure() {
    _totalCalls++;
    _failedCalls++;
    switch (_effectiveState) {
      case CircuitState.closed:
        if (policy.windowMode == CircuitBreakerWindowMode.slidingWindow) {
          _pushWindow(false);
          if (_windowFailures >= policy.failureThreshold) _open();
        } else {
          _failureCount++;
          if (_failureCount >= policy.failureThreshold) _open();
        }
      case CircuitState.halfOpen:
        _open(); // probe failed — re-open immediately
      case CircuitState.open:
        break;
    }
  }

  void _pushWindow(bool success) {
    if (_window.length >= policy.windowSize) {
      final evicted = _window.removeAt(0);
      if (!evicted) _windowFailures--;
    }
    _window.add(success);
    if (!success) _windowFailures++;
  }

  void _open() {
    final prev = _state;
    _state = CircuitState.open;
    _openedAt = DateTime.now();
    _failureCount = 0;
    _successCount = 0;
    _halfOpenSlotTaken = false;
    _window.clear();
    _windowFailures = 0;
    _lastTransitionAt = _openedAt;
    _fireStateChange(prev, CircuitState.open);
  }

  void _close() {
    final prev = _state;
    _state = CircuitState.closed;
    _failureCount = 0;
    _successCount = 0;
    _openedAt = null;
    _halfOpenSlotTaken = false;
    _window.clear();
    _windowFailures = 0;
    _lastTransitionAt = DateTime.now();
    _fireStateChange(prev, CircuitState.closed);
  }

  /// Manually resets the circuit to [CircuitState.closed].
  ///
  /// Use this in integration tests or during graceful recovery scenarios.
  void reset() => _close();

  // ---------------------------------------------------------------------------
  // Metrics and callbacks
  // ---------------------------------------------------------------------------

  /// Registers [callback] to be invoked on every state transition.
  ///
  /// Multiple listeners are supported and called in registration order.
  /// The returned [Subscription] can be used to remove the listener when it
  /// is no longer needed, preventing leaks in long-lived components:
  ///
  /// ```dart
  /// final sub = state.addStateChangeListener((from, to) {
  ///   log.info('Circuit ${policy.circuitName}: $from → $to');
  /// });
  /// // later:
  /// sub.cancel();
  /// ```
  Subscription addStateChangeListener(CircuitStateChangeCallback callback) {
    _listeners.add(callback);
    return _ListenerSubscription(callback, _listeners);
  }

  /// Increments the rejected-calls counter.
  ///
  /// Called by the execution policy when a request is turned away because
  /// the circuit is open (or the half-open probe slot is taken).
  void recordRejected() => _rejectedCalls++;

  /// Returns an immutable snapshot of the current runtime metrics.
  CircuitBreakerMetrics get metrics => CircuitBreakerMetrics(
        totalCalls: _totalCalls,
        successfulCalls: _successfulCalls,
        failedCalls: _failedCalls,
        rejectedCalls: _rejectedCalls,
        consecutiveFailures: _failureCount,
        consecutiveSuccesses: _successCount,
        lastTransitionAt: _lastTransitionAt,
      );

  void _fireStateChange(CircuitState from, CircuitState to) {
    if (from == to) return; // defensive: no-op on identity transition
    for (final listener in _listeners) {
      listener(from, to);
    }
  }

  /// Earliest time at which the circuit will probe again.
  ///
  /// Returns `null` when the circuit is not open.
  DateTime? get retryAfter {
    if (_state != CircuitState.open) return null;
    return _openedAt?.add(policy.breakDuration);
  }

  @override
  String toString() =>
      'CircuitBreakerState(name=${policy.circuitName}, state=$_state, '
      'failures=$_failureCount)';
}

// ---------------------------------------------------------------------------
// Registry (singleton-per-name)
// ---------------------------------------------------------------------------

/// A simple registry that maps circuit names to their [CircuitBreakerState].
///
/// Implementing a Singleton registry at the isolate level ensures that all
/// HTTP clients sharing the same circuit name see a consistent view of
/// circuit state.
final class CircuitBreakerRegistry {
  /// Creates a new isolated [CircuitBreakerRegistry].
  ///
  /// Use the public constructor to create per-test or per-isolate registries.
  /// Use [CircuitBreakerRegistry.instance] for the process-wide shared registry.
  CircuitBreakerRegistry();

  /// The process-wide default registry instance.
  static final CircuitBreakerRegistry instance = CircuitBreakerRegistry();

  final Map<String, CircuitBreakerState> _circuits = {};

  /// Returns the [CircuitBreakerState] for [`policy.circuitName`], creating it
  /// lazily if it does not yet exist.
  CircuitBreakerState getOrCreate(CircuitBreakerPolicy policy) =>
      _circuits.putIfAbsent(
        policy.circuitName,
        () => CircuitBreakerState(policy: policy),
      );

  /// Resets all circuits.  Useful between integration-test runs.
  void resetAll() {
    for (final state in _circuits.values) {
      state.reset();
    }
  }

  /// Removes all registered circuits.
  void clear() => _circuits.clear();
}
