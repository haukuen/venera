import 'dart:async';
import 'dart:collection';

import 'package:venera/foundation/res.dart';
import 'package:venera/network/cache.dart';

class FavoriteChange {
  final String source;
  final String? comicId;
  final String? folderId;
  final bool? isFavorited;
  final String operation;

  const FavoriteChange({
    required this.source,
    required this.operation,
    this.comicId,
    this.folderId,
    this.isFavorited,
  });
}

class SourceOperationCoordinator {
  SourceOperationCoordinator._();

  static final SourceOperationCoordinator instance =
      SourceOperationCoordinator._();

  final _querySlots = _AsyncSemaphore(4);
  final Map<String, _AsyncReadWriteLock> _sourceLocks = {};
  final _favoriteChanges = StreamController<FavoriteChange>.broadcast();

  Stream<FavoriteChange> get favoriteChanges => _favoriteChanges.stream;

  _AsyncReadWriteLock _lockFor(String source) {
    return _sourceLocks.putIfAbsent(source, _AsyncReadWriteLock.new);
  }

  Future<T> query<T>(String source, Future<T> Function() operation) async {
    var releaseSlot = await _querySlots.acquire();
    try {
      return await _lockFor(source).read(operation);
    } finally {
      releaseSlot();
    }
  }

  Future<T> write<T>(String source, Future<T> Function() operation) {
    return _lockFor(source).write(operation);
  }

  Future<Res<T>> guiFavoriteWrite<T>({
    required String source,
    required String operation,
    String? comicId,
    String? folderId,
    required Future<Res<T>> Function() write,
  }) {
    return this.write(source, () async {
      var result = await write();
      if (result.success) {
        favoriteChanged(
          FavoriteChange(
            source: source,
            operation: operation,
            comicId: comicId,
            folderId: folderId,
          ),
        );
      }
      return result;
    });
  }

  void favoriteChanged(FavoriteChange change) {
    NetworkCacheManager().clear();
    _favoriteChanges.add(change);
  }
}

class _AsyncSemaphore {
  int _available;
  final Queue<Completer<void>> _waiters = Queue();

  _AsyncSemaphore(this._available);

  Future<void Function()> acquire() async {
    if (_available > 0) {
      _available--;
    } else {
      var waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _available++;
      }
    };
  }
}

enum _LockKind { read, write }

class _LockRequest {
  final _LockKind kind;
  final Completer<void> completer = Completer<void>();

  _LockRequest(this.kind);
}

class _AsyncReadWriteLock {
  int _readers = 0;
  bool _writing = false;
  final Queue<_LockRequest> _queue = Queue();

  Future<T> read<T>(Future<T> Function() operation) async {
    await _acquire(_LockKind.read);
    try {
      return await operation();
    } finally {
      _releaseRead();
    }
  }

  Future<T> write<T>(Future<T> Function() operation) async {
    await _acquire(_LockKind.write);
    try {
      return await operation();
    } finally {
      _releaseWrite();
    }
  }

  Future<void> _acquire(_LockKind kind) {
    if (kind == _LockKind.read && !_writing && _queue.isEmpty) {
      _readers++;
      return Future.value();
    }
    if (kind == _LockKind.write && !_writing && _readers == 0) {
      _writing = true;
      return Future.value();
    }
    var request = _LockRequest(kind);
    _queue.add(request);
    return request.completer.future;
  }

  void _releaseRead() {
    _readers--;
    _drain();
  }

  void _releaseWrite() {
    _writing = false;
    _drain();
  }

  void _drain() {
    if (_writing || _readers > 0 || _queue.isEmpty) return;
    if (_queue.first.kind == _LockKind.write) {
      _writing = true;
      _queue.removeFirst().completer.complete();
      return;
    }
    while (_queue.isNotEmpty && _queue.first.kind == _LockKind.read) {
      _readers++;
      _queue.removeFirst().completer.complete();
    }
  }
}
