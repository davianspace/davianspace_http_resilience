import 'dart:async';

/// A cooperative cancellation primitive for the HTTP pipeline.
///
/// [CancellationToken] wraps Dart's built-in [Future]/[Stream] cancellation
/// mechanism and provides an explicit `cancel()` surface, making it easy to
/// wire UI dismissals or app-lifecycle events into long-running HTTP chains.
///
/// ### Usage
/// ```dart
/// final token = CancellationToken();
///
/// // Somewhere in your widget:
/// onDispose: () => token.cancel('Widget disposed'),
///
/// // Inside the pipeline:
/// token.throwIfCancelled();
/// ```
final class CancellationToken {
  bool _cancelled = false;
  String? _reason;
  final List<void Function(String?)> _listeners = [];

  /// `true` once [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// The reason supplied when [cancel] was called, or `null`.
  String? get reason => _reason;

  /// Cancels the token with an optional human-readable [reason].
  ///
  /// All registered listeners are notified synchronously.
  /// Calling [cancel] more than once is a no-op.
  void cancel([String? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final listener in _listeners) {
      listener(_reason);
    }
    _listeners.clear();
  }

  /// Registers a [listener] that is invoked when the token is cancelled.
  ///
  /// If the token is already cancelled the listener is called immediately.
  void addListener(void Function(String? reason) listener) {
    if (_cancelled) {
      listener(_reason);
    } else {
      _listeners.add(listener);
    }
  }

  /// Throws a [CancellationException] if this token has been cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw CancellationException(reason: _reason);
  }

  /// Returns a [Future] that completes when the token is cancelled.
  Future<void> get onCancelled {
    if (_cancelled) return Future.value();
    // ignore: cancel_subscriptions
    final completer = _AsyncCompleter<void>();
    addListener((_) => completer.complete());
    return completer.future;
  }

  @override
  String toString() =>
      'CancellationToken(cancelled=$_cancelled, reason=$_reason)';
}

// ---------------------------------------------------------------------------
// Helper — thin wrapper around dart:async Completer
// ---------------------------------------------------------------------------

class _AsyncCompleter<T> {
  _AsyncCompleter() : _inner = Completer<T>();

  final Completer<T> _inner;

  void complete([FutureOr<T>? value]) {
    if (!_inner.isCompleted) _inner.complete(value as T);
  }

  Future<T> get future => _inner.future;
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

/// Thrown by [CancellationToken.throwIfCancelled] when the token has
/// been cancelled.
final class CancellationException implements Exception {
  const CancellationException({this.reason});

  /// The reason the operation was cancelled, if supplied.
  final String? reason;

  @override
  String toString() => 'CancellationException: operation was cancelled'
      '${reason != null ? " ($reason)" : ""}';
}
