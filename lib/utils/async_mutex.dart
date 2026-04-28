import 'dart:async';

/// A mutual exclusion lock for async operations.
///
/// Replaces busy-wait patterns (while+Future.delayed) with
/// [Completer]-based queuing so waiters consume no CPU.
class AsyncMutex {
  Completer<void>? _completer;

  /// Runs [fn] exclusively. If another call is in progress, the
  /// caller waits without consuming CPU.
  Future<T> run<T>(Future<T> Function() fn) async {
    while (true) {
      final c = _completer;
      if (c == null) break;
      await c.future;
    }
    _completer = Completer<void>();
    try {
      return await fn();
    } finally {
      final c = _completer!;
      _completer = null;
      c.complete();
    }
  }
}

/// Limits concurrent async operations to at most [max] at a time.
///
/// Replaces busy-wait semaphore patterns. Waiters are queued and
/// resume without consuming CPU when a slot opens.
class AsyncSemaphore {
  final int _max;
  int _acquired = 0;
  final _queue = <Completer<void>>[];

  AsyncSemaphore(this._max);

  Future<T> run<T>(Future<T> Function() fn) async {
    final completer = Completer<void>();
    _queue.add(completer);
    _advance();
    await completer.future;
    try {
      return await fn();
    } finally {
      _acquired--;
      _advance();
    }
  }

  void _advance() {
    while (_acquired < _max && _queue.isNotEmpty) {
      _acquired++;
      _queue.removeAt(0).complete();
    }
  }
}
