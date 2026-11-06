/// In-memory [SyncTransport] implementation used by sync-engine tests and for
/// local multi-device simulation.
///
/// Several [FakeTransport] instances can share one [FakeRemote]; the remote
/// models a single WebDAV server, so every device only writes its own branch
/// and all other devices can observe it.
///
/// The implementation is deliberately deterministic: there is no randomness,
/// no wall-clock dependency and no timer unless a test explicitly configures
/// [FakeRemote.latency] or [FakeRemote.onRequest]. Faults are injected
/// explicitly through [FakeRemote] and never happen implicitly.
///
/// This library is pure Dart (no Flutter imports) so it runs in plain
/// `dart test` / `flutter test` without bindings.
library;

import 'dart:typed_data';

import 'hlc.dart';
import 'op.dart';
import 'snapshot.dart';
import 'transport.dart';

/// Bytes returned by [FakeRemote.corruptChange] reads: a deliberately
/// truncated gzip header that [SyncOpCodec.decode] rejects with a
/// [FormatException].
final Uint8List _corruptChangeBytes = Uint8List.fromList(const [
  0x1f,
  0x8b,
  0x08,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x03,
  0xde,
  0xad,
]);

String _rangeKey(int lo, int hi) => '$lo-$hi';

void _checkDeviceId(String deviceId) {
  if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
    throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
  }
}

void _checkRange(int lo, int hi) {
  if (lo <= 0) {
    throw ArgumentError.value(lo, 'lo', 'Change range lo must be positive');
  }
  if (hi < lo) {
    throw ArgumentError.value(hi, 'hi', 'Change range hi must be >= lo');
  }
}

void _checkSha256(String sha256) {
  if (!_sha256RegExp.hasMatch(sha256)) {
    throw ArgumentError.value(sha256, 'sha256', 'Invalid sha256');
  }
}

final RegExp _sha256RegExp = RegExp(r'^[0-9a-f]{64}$');

/// One simulated WebDAV server shared by several [FakeTransport]s.
///
/// Storage is keyed exactly like the v2 remote layout, so tests can assert on
/// the layout through the [debug] accessors without reaching into internals.
class FakeRemote {
  FakeRemote({this.latency = Duration.zero});

  /// Delay applied before every operation (simulated network latency).
  ///
  /// Tests that need determinism should leave this at [Duration.zero] and gate
  /// concurrency with [onRequest] instead.
  Duration latency;

  /// Optional hook awaited before every operation.
  ///
  /// A test can assign a closure that awaits a `Completer` future to keep a
  /// request in flight while it checks for races, or counts calls.
  Future<void> Function()? onRequest;

  // --------------------------------------------------------------- storage --

  final Map<String, RemoteState> _states = {};
  final Map<String, Map<String, Uint8List>> _changes = {};
  final Map<String, Uint8List> _snapshots = {};
  final Map<String, Uint8List> _snapshotPrev = {};
  final Map<String, Map<String, Uint8List>> _blobs = {};

  /// Device directories that exist even when they currently hold no files.
  final Set<String> _deviceDirs = {};

  Uint8List? _schema;

  // ----------------------------------------------------------------- faults --

  /// Range keys (`deviceId|lo-hi`) whose change file disappears from listings
  /// and reads as absent.
  final Set<String> _missingChanges = {};

  /// Range keys whose change file stays listed but yields corrupt bytes.
  final Set<String> _corruptChanges = {};

  /// Device ids whose `readState` throws a simulated I/O failure.
  final Set<String> _stateReadFailures = {};

  /// Device ids whose `readState` throws a simulated parse failure.
  final Set<String> _corruptStates = {};

  /// Device ids whose `readState` answers with a frozen (stale) state.
  final Map<String, RemoteState?> _staleStates = {};

  /// Device ids whose snapshot reads return a truncated file.
  final Map<String, int?> _partialSnapshots = {};

  int _pendingWriteFailures = 0;
  bool _failWritesAfterCommit = false;
  bool _unavailable = false;
  bool _readOnly = false;
  bool _writeOnly = false;

  final List<String> _log = [];

  // ------------------------------------------------------------ inspection --

  /// Ordered operation log (`operation[:device]`), useful for assertions.
  List<String> get log => List.unmodifiable(_log);

  /// Number of transport operations observed so far.
  int get requestCount => _log.length;

  void clearLog() => _log.clear();

  bool get unavailable => _unavailable;

  bool get readOnly => _readOnly;

  bool get writeOnly => _writeOnly;

  /// Change files currently stored for [deviceId], keyed by `lo-hi`.
  Map<String, Uint8List> debugChanges(String deviceId) =>
      Map.unmodifiable(_changes[deviceId] ?? const {});

  Uint8List? debugSnapshot(String deviceId) => _snapshots[deviceId];

  Uint8List? debugSnapshotPrev(String deviceId) => _snapshotPrev[deviceId];

  Map<String, Uint8List> debugBlobs(String deviceId) =>
      Map.unmodifiable(_blobs[deviceId] ?? const {});

  Uint8List? get debugSchema => _schema;

  // ---------------------------------------------------------- fault control --

  /// Marks `changes/<lo>-<hi>` of [deviceId] as missing: it is not listed and
  /// reads as `null`.
  void missingChange(String deviceId, int lo, int hi) {
    _checkDeviceId(deviceId);
    _checkRange(lo, hi);
    _missingChanges.add('$deviceId|${_rangeKey(lo, hi)}');
  }

  /// Marks `changes/<lo>-<hi>` of [deviceId] as corrupt: it stays listed, but
  /// reads return bytes that fail to decode.
  void corruptChange(String deviceId, int lo, int hi) {
    _checkDeviceId(deviceId);
    _checkRange(lo, hi);
    _corruptChanges.add('$deviceId|${_rangeKey(lo, hi)}');
  }

  /// Marks a change range as broken in the way that matters for gap repair:
  /// it is hidden from listings *and* unreadable if requested by range.
  void missingCorruptChange(String deviceId, int lo, int hi) {
    missingChange(deviceId, lo, hi);
    corruptChange(deviceId, lo, hi);
  }

  /// Restores normal behaviour for one change range.
  void clearChangeFault(String deviceId, int lo, int hi) {
    _checkDeviceId(deviceId);
    _checkRange(lo, hi);
    final key = '$deviceId|${_rangeKey(lo, hi)}';
    _missingChanges.remove(key);
    _corruptChanges.remove(key);
  }

  /// Makes the next [count] write operations fail.
  ///
  /// With [afterCommit] the write is applied to the remote and *then* the
  /// error is reported, which models an ambiguous network failure and lets
  /// tests prove that retrying the same content over the same name is
  /// idempotent.
  void failNextWrite({int count = 1, bool afterCommit = false}) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Must be >= 0');
    }
    _pendingWriteFailures += count;
    _failWritesAfterCommit = afterCommit;
  }

  /// Freezes the current state of [deviceId]; [FakeTransport.readState] keeps
  /// returning it until [clearStaleState] is called, even when writes update
  /// the real state. This models "state file lags behind change files".
  void staleState(String deviceId) {
    _checkDeviceId(deviceId);
    _staleStates[deviceId] = _copyState(_states[deviceId]);
  }

  void clearStaleState(String deviceId) {
    _checkDeviceId(deviceId);
    _staleStates.remove(deviceId);
  }

  /// Makes [FakeTransport.readState] throw (simulated transient I/O error).
  void failStateRead(String deviceId, {bool enabled = true}) {
    _checkDeviceId(deviceId);
    if (enabled) {
      _stateReadFailures.add(deviceId);
    } else {
      _stateReadFailures.remove(deviceId);
    }
  }

  /// Makes [FakeTransport.readState] throw (simulated invalid JSON).
  void corruptState(String deviceId, {bool enabled = true}) {
    _checkDeviceId(deviceId);
    if (enabled) {
      _corruptStates.add(deviceId);
    } else {
      _corruptStates.remove(deviceId);
    }
  }

  /// Truncates snapshot reads for [deviceId] to [length] bytes (default: half
  /// of the file), simulating a non-atomic overwrite.
  void injectPartialSnapshot(String deviceId, {int? length}) {
    _checkDeviceId(deviceId);
    if (length != null && length < 0) {
      throw ArgumentError.value(length, 'length', 'Must be >= 0');
    }
    _partialSnapshots[deviceId] = length;
  }

  void clearPartialSnapshot(String deviceId) {
    _checkDeviceId(deviceId);
    _partialSnapshots.remove(deviceId);
  }

  /// Makes every transport operation throw (server unreachable).
  void setUnavailable(bool value) => _unavailable = value;

  /// Writes throw with status 403, reads still work.
  void setReadOnly(bool value) {
    _readOnly = value;
    if (value) _writeOnly = false;
  }

  /// Reads throw with status 403, writes still work.
  void setWriteOnly(bool value) {
    _writeOnly = value;
    if (value) _readOnly = false;
  }

  /// Clears every injected fault but keeps the stored data.
  void clearFaults() {
    _missingChanges.clear();
    _corruptChanges.clear();
    _stateReadFailures.clear();
    _corruptStates.clear();
    _staleStates.clear();
    _partialSnapshots.clear();
    _pendingWriteFailures = 0;
    _failWritesAfterCommit = false;
    _unavailable = false;
    _readOnly = false;
    _writeOnly = false;
  }

  // -------------------------------------------------------------- internal --

  static RemoteState? _copyState(RemoteState? state) {
    if (state == null) return null;
    return RemoteState.fromJson(Map<String, Object?>.from(state.toJson()));
  }

  Uint8List? _snapshotBytes(String deviceId) {
    var bytes = _snapshots[deviceId];
    if (bytes == null || bytes.isEmpty) {
      bytes = _snapshotPrev[deviceId];
    }
    if (bytes == null || bytes.isEmpty) return null;
    final partialLength = _partialSnapshots[deviceId];
    if (partialLength != null) {
      final length = partialLength < bytes.length
          ? partialLength
          : bytes.length;
      return Uint8List.sublistView(bytes, 0, length);
    }
    return bytes;
  }
}

/// A [SyncTransport] backed by a shared [FakeRemote].
///
/// The transport itself is stateless besides the closed flag; the device that
/// performs a write is identified by the `deviceId` argument of the transport
/// method, exactly like the real WebDAV transport.
class FakeTransport implements SyncTransport {
  FakeTransport(this.remote, {this.label});

  final FakeRemote remote;

  /// Optional human readable label used in [FakeRemote.log].
  final String? label;

  bool _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  Future<void> _enter(String operation) async {
    if (_closed) {
      throw SyncTransportException('Fake transport is closed');
    }
    remote._log.add(label == null ? operation : '$label:$operation');
    if (remote.latency > Duration.zero) {
      await Future<void>.delayed(remote.latency);
    }
    final hook = remote.onRequest;
    if (hook != null) await hook();
    if (remote._unavailable) {
      throw SyncTransportException('Fake remote unavailable', statusCode: 503);
    }
  }

  Future<T> _read<T>(String operation, T Function() action) async {
    await _enter(operation);
    if (remote._writeOnly) {
      throw SyncTransportException(
        'Fake remote is write-only',
        statusCode: 403,
      );
    }
    return action();
  }

  Future<void> _write(String operation, void Function() action) async {
    await _enter(operation);
    if (remote._readOnly) {
      throw SyncTransportException('Fake remote is read-only', statusCode: 403);
    }
    final fail = remote._pendingWriteFailures > 0;
    if (fail) remote._pendingWriteFailures--;
    if (fail && !remote._failWritesAfterCommit) {
      throw SyncTransportException(
        'Injected write failure for $operation',
        statusCode: 500,
      );
    }
    action();
    if (fail && remote._failWritesAfterCommit) {
      throw SyncTransportException(
        'Injected write failure (data was committed) for $operation',
        statusCode: 500,
      );
    }
  }

  // ------------------------------------------------------------ device list --

  @override
  Future<List<RemoteDeviceInfo>> listDevices() => _read('listDevices', () {
    final ids = <String>{
      ...remote._states.keys,
      ...remote._deviceDirs,
      ...remote._changes.keys,
      ...remote._snapshots.keys,
      ...remote._snapshotPrev.keys,
      ...remote._blobs.keys,
    };
    final sorted = ids.where(hlcDeviceIdRegExp.hasMatch).toList()..sort();
    return [for (final id in sorted) RemoteDeviceInfo(deviceId: id)];
  });

  // ------------------------------------------------------------------ state --

  @override
  Future<RemoteState?> readState(String deviceId) async {
    _checkDeviceId(deviceId);
    return _read('readState:$deviceId', () {
      if (remote._stateReadFailures.contains(deviceId)) {
        throw SyncTransportException(
          'Injected state read failure for $deviceId',
          statusCode: 500,
        );
      }
      if (remote._corruptStates.contains(deviceId)) {
        throw SyncTransportException('Injected corrupt state for $deviceId');
      }
      if (remote._staleStates.containsKey(deviceId)) {
        return FakeRemote._copyState(remote._staleStates[deviceId]);
      }
      return FakeRemote._copyState(remote._states[deviceId]);
    });
  }

  @override
  Future<void> writeState(String deviceId, RemoteState state) async {
    _checkDeviceId(deviceId);
    if (state.deviceId != deviceId) {
      throw ArgumentError.value(
        state.deviceId,
        'state.deviceId',
        'Must match $deviceId',
      );
    }
    await _write('writeState:$deviceId', () {
      remote._states[deviceId] = FakeRemote._copyState(state)!;
    });
  }

  // ---------------------------------------------------------------- changes --

  @override
  Future<List<ChangeRange>> listChanges(String deviceId) async {
    _checkDeviceId(deviceId);
    return _read('listChanges:$deviceId', () {
      final files = remote._changes[deviceId];
      if (files == null) return const <ChangeRange>[];
      final ranges = <ChangeRange>[];
      for (final key in files.keys) {
        if (remote._missingChanges.contains('$deviceId|$key')) continue;
        final parts = key.split('-');
        if (parts.length != 2) continue;
        final lo = int.tryParse(parts[0]);
        final hi = int.tryParse(parts[1]);
        if (lo == null || hi == null) continue;
        ranges.add(ChangeRange(lo: lo, hi: hi));
      }
      ranges.sort((a, b) {
        final byLo = a.lo.compareTo(b.lo);
        return byLo != 0 ? byLo : a.hi.compareTo(b.hi);
      });
      return ranges;
    });
  }

  @override
  Future<Uint8List?> readChanges(String deviceId, ChangeRange range) async {
    _checkDeviceId(deviceId);
    _checkRange(range.lo, range.hi);
    return _read('readChanges:$deviceId:${_rangeKey(range.lo, range.hi)}', () {
      final key = '$deviceId|${_rangeKey(range.lo, range.hi)}';
      if (remote._corruptChanges.contains(key)) {
        return Uint8List.fromList(_corruptChangeBytes);
      }
      if (remote._missingChanges.contains(key)) return null;
      final bytes = remote._changes[deviceId]?[_rangeKey(range.lo, range.hi)];
      return bytes == null ? null : Uint8List.fromList(bytes);
    });
  }

  @override
  Future<void> writeChanges(
    String deviceId,
    int lo,
    int hi,
    Uint8List bytes,
  ) async {
    _checkDeviceId(deviceId);
    _checkRange(lo, hi);
    await _write('writeChanges:$deviceId:${_rangeKey(lo, hi)}', () {
      final files = remote._changes.putIfAbsent(deviceId, () => {});
      files[_rangeKey(lo, hi)] = Uint8List.fromList(bytes);
      remote._deviceDirs.add(deviceId);
      final faultKey = '$deviceId|${_rangeKey(lo, hi)}';
      remote._missingChanges.remove(faultKey);
      remote._corruptChanges.remove(faultKey);
    });
  }

  @override
  Future<void> deleteChanges(String deviceId, int upToSeq) async {
    _checkDeviceId(deviceId);
    if (upToSeq < 0) {
      throw ArgumentError.value(upToSeq, 'upToSeq', 'Must be >= 0');
    }
    await _write('deleteChanges:$deviceId:$upToSeq', () {
      final files = remote._changes[deviceId];
      if (files == null) return;
      final removed = <String>[];
      files.removeWhere((key, _) {
        final parts = key.split('-');
        if (parts.length != 2) return false;
        final hi = int.tryParse(parts[1]);
        if (hi == null || hi > upToSeq) return false;
        removed.add(key);
        return true;
      });
      for (final key in removed) {
        final faultKey = '$deviceId|$key';
        remote._missingChanges.remove(faultKey);
        remote._corruptChanges.remove(faultKey);
      }
    });
  }

  // --------------------------------------------------------------- snapshot --

  @override
  Future<Uint8List?> readSnapshot(String deviceId) async {
    _checkDeviceId(deviceId);
    return _read('readSnapshot:$deviceId', () {
      final bytes = remote._snapshotBytes(deviceId);
      return bytes == null ? null : Uint8List.fromList(bytes);
    });
  }

  @override
  Future<SnapshotInfo?> readSnapshotInfo(String deviceId) async {
    _checkDeviceId(deviceId);
    return _read('readSnapshotInfo:$deviceId', () {
      final bytes = remote._snapshotBytes(deviceId);
      if (bytes == null) return null;
      try {
        final info = SnapshotInfo.fromJson(SyncOpCodec.decodeFirstLine(bytes));
        if (info.deviceId != deviceId) {
          throw FormatException(
            'Snapshot device mismatch: ${info.deviceId} != $deviceId',
          );
        }
        return info;
      } on FormatException catch (error) {
        throw SyncTransportException(
          'Invalid snapshot info for $deviceId: ${error.message}',
          cause: error,
        );
      } on ArgumentError catch (error) {
        throw SyncTransportException(
          'Invalid snapshot info for $deviceId: ${error.message}',
          cause: error,
        );
      }
    });
  }

  @override
  Future<void> writeSnapshot(String deviceId, Uint8List bytes) async {
    _checkDeviceId(deviceId);
    await _write('writeSnapshot:$deviceId', () {
      final previous = remote._snapshots[deviceId];
      if (previous != null) {
        remote._snapshotPrev[deviceId] = previous;
      }
      remote._snapshots[deviceId] = Uint8List.fromList(bytes);
      remote._deviceDirs.add(deviceId);
      remote._partialSnapshots.remove(deviceId);
    });
  }

  // ------------------------------------------------------------------ blobs --

  @override
  Future<Uint8List?> readBlob(String deviceId, String sha256) async {
    _checkDeviceId(deviceId);
    _checkSha256(sha256);
    return _read('readBlob:$deviceId:$sha256', () {
      final bytes = remote._blobs[deviceId]?[sha256];
      return bytes == null ? null : Uint8List.fromList(bytes);
    });
  }

  @override
  Future<void> writeBlob(
    String deviceId,
    String sha256,
    Uint8List bytes,
  ) async {
    _checkDeviceId(deviceId);
    _checkSha256(sha256);
    await _write('writeBlob:$deviceId:$sha256', () {
      remote._blobs.putIfAbsent(deviceId, () => {})[sha256] =
          Uint8List.fromList(bytes);
      remote._deviceDirs.add(deviceId);
    });
  }

  // ------------------------------------------------------------- management --

  @override
  Future<void> deleteDevice(String deviceId) async {
    _checkDeviceId(deviceId);
    await _write('deleteDevice:$deviceId', () {
      remote._states.remove(deviceId);
      remote._changes.remove(deviceId);
      remote._snapshots.remove(deviceId);
      remote._snapshotPrev.remove(deviceId);
      remote._blobs.remove(deviceId);
      remote._deviceDirs.remove(deviceId);
      remote._staleStates.remove(deviceId);
      remote._partialSnapshots.remove(deviceId);
      remote._stateReadFailures.remove(deviceId);
      remote._corruptStates.remove(deviceId);
      final prefix = '$deviceId|';
      remote._missingChanges.removeWhere((key) => key.startsWith(prefix));
      remote._corruptChanges.removeWhere((key) => key.startsWith(prefix));
    });
  }

  @override
  Future<void> ensureSchema(Uint8List schemaJson) async {
    if (schemaJson.isEmpty) {
      throw ArgumentError.value(schemaJson, 'schemaJson', 'Must not be empty');
    }
    await _write('ensureSchema', () {
      remote._schema ??= Uint8List.fromList(schemaJson);
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    remote._log.add(label == null ? 'close' : '$label:close');
  }
}
