// Tests for CircuitBreakerWindowMode.slidingWindow added in Phase 6.3.
// Consecutive mode (the existing default) is also smoke-tested to confirm
// the new enum addition did not break anything.

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

CircuitBreakerState _slidingState({
  int failureThreshold = 3,
  int windowSize = 5,
  String name = 'test',
}) =>
    CircuitBreakerState(
      policy: CircuitBreakerPolicy(
        circuitName: name,
        failureThreshold: failureThreshold,
        windowSize: windowSize,
        windowMode: CircuitBreakerWindowMode.slidingWindow,
      ),
    );

// ════════════════════════════════════════════════════════════════════════════
//  Enum / policy defaults
// ════════════════════════════════════════════════════════════════════════════

void main() {
  group('CircuitBreakerPolicy — windowMode defaults', () {
    test('default windowMode is consecutive', () {
      const policy = CircuitBreakerPolicy();
      expect(policy.windowMode, CircuitBreakerWindowMode.consecutive);
    });

    test('default windowSize is 10', () {
      const policy = CircuitBreakerPolicy();
      expect(policy.windowSize, 10);
    });

    test('slidingWindow can be set explicitly', () {
      const policy = CircuitBreakerPolicy(
        circuitName: 'sw',
        windowMode: CircuitBreakerWindowMode.slidingWindow,
        windowSize: 20,
      );
      expect(policy.windowMode, CircuitBreakerWindowMode.slidingWindow);
      expect(policy.windowSize, 20);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Sliding-window opening logic
  // ──────────────────────────────────────────────────────────────────────────

  group('CircuitBreakerState — sliding window opening', () {
    test('opens when failure count in window reaches threshold', () {
      final state = _slidingState();

      state.recordSuccess();
      state.recordSuccess();
      state.recordFailure();
      state.recordFailure();
      expect(state.state, CircuitState.closed); // 2 failures — not yet
      state.recordFailure(); // 3rd failure → open
      expect(state.state, CircuitState.open);
    });

    test('does not open when failures are below threshold', () {
      final state = _slidingState(windowSize: 10);
      state.recordFailure();
      state.recordFailure();
      expect(state.state, CircuitState.closed);
    });

    test('opens immediately on first call if threshold is 1', () {
      final state = _slidingState(failureThreshold: 1);
      state.recordFailure();
      expect(state.state, CircuitState.open);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Window eviction
  // ──────────────────────────────────────────────────────────────────────────

  group('CircuitBreakerState — sliding window eviction', () {
    test('old failure evicted by new success lowers failure count', () {
      // window size = 3, threshold = 3
      // Push F, F, S → window [F, F, S] — 2 failures, still closed.
      // Push F → evicts oldest F → window [F, S, F] — 2 failures, still closed.
      // Push F → evicts oldest F → window [S, F, F] — 2 still closed.
      // Push F → evicts S → window [F, F, F] — 3 failures → opens.
      final state = _slidingState(windowSize: 3);

      state.recordFailure(); // [F]         failures=1
      state.recordFailure(); // [F, F]      failures=2
      state.recordSuccess(); // [F, F, S]   failures=2
      expect(state.state, CircuitState.closed);

      state.recordFailure(); // [F, S, F]   failures=2 (oldest F evicted)
      expect(state.state, CircuitState.closed);

      state.recordFailure(); // [S, F, F]   oldest F evicted → still 2
      expect(state.state, CircuitState.closed);

      state.recordFailure(); // [F, F, F]   S evicted → failures=3 → open
      expect(state.state, CircuitState.open);
    });

    test('successes do not accumulate failures outside window', () {
      // window size = 4, threshold = 3
      // Fill with 2 failures + 2 successes.  Should stay closed regardless
      // of how many successes follow (they push old failures out).
      final state = _slidingState(windowSize: 4);

      state.recordFailure();
      state.recordFailure(); // [F, F] — 2 failures
      state.recordSuccess();
      state.recordSuccess(); // [F, F, S, S] — still 2 failures
      expect(state.state, CircuitState.closed);

      // Two more successes push both failures out of the window.
      state.recordSuccess();
      state.recordSuccess(); // [S, S, S, S] — 0 failures
      expect(state.state, CircuitState.closed);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Window reset on state transitions
  // ──────────────────────────────────────────────────────────────────────────

  group('CircuitBreakerState — window cleared on transitions', () {
    test('window is cleared when the circuit opens', () {
      final state = _slidingState(failureThreshold: 2);

      state.recordFailure();
      state.recordFailure(); // opens + clears window
      expect(state.state, CircuitState.open);

      // Reset → closed.  Window should be empty — need 2 fresh failures.
      state.reset();
      expect(state.state, CircuitState.closed);

      state.recordFailure();
      expect(state.state, CircuitState.closed); // only 1 failure since reset
      state.recordFailure();
      expect(state.state, CircuitState.open);
    });

    test('window is cleared when circuit is reset to closed', () {
      final state = _slidingState(failureThreshold: 2);
      state.recordFailure();
      state.recordFailure(); // open
      state.reset();

      // After reset the window is empty — a single failure should not open.
      state.recordFailure();
      expect(state.state, CircuitState.closed);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  //  Consecutive mode regression
  // ──────────────────────────────────────────────────────────────────────────

  group('CircuitBreakerState — consecutive mode (regression)', () {
    test('successive failures open the circuit', () {
      final state = CircuitBreakerState(
        policy: const CircuitBreakerPolicy(
          circuitName: 'consec',
          failureThreshold: 2,
        ),
      );

      state.recordFailure();
      expect(state.state, CircuitState.closed);
      state.recordFailure();
      expect(state.state, CircuitState.open);
    });

    test('success between failures resets the consecutive streak', () {
      final state = CircuitBreakerState(
        policy: const CircuitBreakerPolicy(
          circuitName: 'consec',
          failureThreshold: 2,
        ),
      );

      state.recordFailure();
      state.recordSuccess(); // streak reset
      state.recordFailure();
      expect(state.state, CircuitState.closed); // only 1 consecutive failure
    });
  });
}
