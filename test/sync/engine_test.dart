/// Tests for the v2 sync engine orchestration.
///
/// Everything here runs in-process: [_MemStore] implements [SyncStore] and
/// [_FakeTransport] implements [SyncTransport], both declared in this file on
/// purpose (the deliverable must not add `lib/` doubles). No network, no
/// WebDAV, no Flutter bindings.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/engine.dart';
import 'package:venera/sync/hlc.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/snapshot.dart';
import 'package:venera/sync/store.dart';
import 'package:venera/sync/transport.dart';
import 'package:venera/sync/version.dart';

const String _deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
const String _deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';
const String _deviceC = 'cccccccc-1111-2222-3333-444444444444';

const String _comic1 = 'comic-1/with@separators';
const String _comic2 = 'comic-2';
const String _comic3 = 'comic-3';
const String _comic4 = 'comic-4';
const String _comic5 = 'comic-5';

// ---------------------------------------------------------------------------
// In-test SyncStore double
// ---------------------------------------------------------------------------

class _RecKey {
  const _RecKey(this.domain, this.key, this.field);

  final String domain;
  final SyncKey key;
  final String field;

  @override
  bool operator ==(Object other) =>
      other is _RecKey &&
      other.domain == domain &&
      other.key == key &&
      other.field == field;

  @override
  int get hashCode => Object.hash(domain, key, field);
}

class _Rec {
  _Rec({required this.version, this.deletedVersion, this.data});

  Version version;
  Version? deletedVersion;
  Map<String, Object?>? data;
}

class _MutableStats {
  int applied = 0;
  int stale = 0;
  int cutoff = 0;
  int duplicates = 0;

  SyncApplyStats build() => SyncApplyStats(
    applied: applied,
    stale: stale,
    skippedByCutoff: cutoff,
    duplicates: duplicates,
  );
}

String _canonicalData(Map<String, Object?>? data) {
  if (data == null) return 'null';
  final keys = data.keys.toList()..sort();
  return jsonEncode(<String, Object?>{for (final key in keys) key: data[key]});
}

/// In-memory [SyncStore] with the same merge semantics the SQLite store must
/// implement (LWW registers, LWW-Element-Set add/del versions, clear cutoffs,
/// watermark max on snapshot apply).
class _MemStore implements SyncStore {
  _MemStore(this.deviceId, {DateTime Function()? now})
    : clock = HlcClock(
        deviceId: deviceId,
        now: now ?? () => DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );

  @override
  final String deviceId;

  @override
  final HlcClock clock;

  int _nextSeq = 0;
  int _lastPush = 0;
  final List<SyncOp> _outbox = <SyncOp>[];
  final Map<_RecKey, _Rec> _records = <_RecKey, _Rec>{};
  final Map<String, Version> _clears = <String, Version>{};
  final Map<String, int> _applied = <String, int>{};
  SnapshotInfo? _lastSnapshot;
  final Map<String, String> _engineMeta = <String, String>{};
  bool initialized = false;
  bool closed = false;

  // --- instrumentation used by the tests -----------------------------------
  int applyOpsCalls = 0;
  int applySnapshotCalls = 0;
  List<SyncOp> lastApplyOpsBatch = const <SyncOp>[];

  bool get isEmpty => _records.isEmpty && _clears.isEmpty;

  @override
  Future<void> init() async {
    initialized = true;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  void _checkOpen() {
    if (closed) throw StateError('store is closed');
  }

  void _mergeOp(SyncOp op, _MutableStats stats) {
    final cutoff = _clears[op.domain];
    if (cutoff != null && op.version < cutoff) {
      stats.cutoff++;
      return;
    }
    if (op.isClear) {
      final previous = _clears[op.domain];
      if (previous == null || op.version > previous) {
        _clears[op.domain] = op.version;
        stats.applied++;
      } else if (op.version == previous) {
        stats.duplicates++;
      } else {
        stats.stale++;
      }
      return;
    }

    final key = _RecKey(op.domain, op.key!, op.field);
    final existing = _records[key];
    if (op.kind == SyncOpKind.del) {
      if (existing == null) {
        _records[key] = _Rec(version: op.version, deletedVersion: op.version);
        stats.applied++;
        return;
      }
      final deleted = existing.deletedVersion;
      if (deleted == null || op.version > deleted) {
        existing.deletedVersion = op.version;
        stats.applied++;
      } else if (op.version == deleted) {
        stats.duplicates++;
      } else {
        stats.stale++;
      }
      return;
    }

    // upsert / add
    if (existing == null) {
      _records[key] = _Rec(
        version: op.version,
        data: op.kind == SyncOpKind.upsert ? op.data : null,
      );
      stats.applied++;
    } else if (op.version > existing.version) {
      existing.version = op.version;
      if (op.kind == SyncOpKind.upsert) existing.data = op.data;
      stats.applied++;
    } else if (op.version == existing.version) {
      stats.duplicates++;
    } else {
      stats.stale++;
    }
  }

  @override
  Future<SyncOp> emit({
    required String domain,
    required SyncKey key,
    String field = '',
    required SyncOpKind kind,
    Map<String, Object?>? data,
  }) async {
    _checkOpen();
    if (kind == SyncOpKind.clear) {
      throw ArgumentError('Clear ops must be emitted with emitClear');
    }
    final hlc = clock.tick();
    final seq = ++_nextSeq;
    final op = SyncOp(
      deviceId: deviceId,
      seq: seq,
      version: Version(hlc, seq),
      domain: domain,
      key: key,
      field: field,
      kind: kind,
      data: data,
    );
    _mergeOp(op, _MutableStats());
    _outbox.add(op);
    return op;
  }

  @override
  Future<SyncOp> emitClear(String domain) async {
    _checkOpen();
    final hlc = clock.tick();
    final seq = ++_nextSeq;
    final op = SyncOp(
      deviceId: deviceId,
      seq: seq,
      version: Version(hlc, seq),
      domain: domain,
      key: null,
      field: '',
      kind: SyncOpKind.clear,
    );
    _mergeOp(op, _MutableStats());
    _outbox.add(op);
    return op;
  }

  @override
  Future<List<SyncOp>> pendingOps({
    int limit = 2000,
    int maxBytes = 1 << 20,
  }) async {
    _checkOpen();
    if (limit <= 0) return const <SyncOp>[];
    return _outbox.take(limit).toList(growable: false);
  }

  @override
  Future<int> pendingCount() async => _outbox.length;

  @override
  Future<int> getNextSeq() async => _nextSeq;

  @override
  Future<int> getLastPush() async => _lastPush;

  @override
  Future<void> markPushed(int upToSeq) async {
    _checkOpen();
    _outbox.removeWhere((op) => op.seq <= upToSeq);
    if (upToSeq > _lastPush) _lastPush = upToSeq;
  }

  @override
  Future<SyncApplyStats> applyOps(Iterable<SyncOp> ops) async {
    _checkOpen();
    applyOpsCalls++;
    final batch = ops.toList(growable: false);
    lastApplyOpsBatch = batch;
    final stats = _MutableStats();
    for (final op in batch) {
      clock.observe(op.version.hlc);
      _mergeOp(op, stats);
    }
    return stats.build();
  }

  @override
  Future<Iterable<StoredRecord>> dumpRecords({Set<String>? domains}) async {
    final result = <StoredRecord>[];
    for (final entry in _records.entries) {
      if (domains != null && !domains.contains(entry.key.domain)) continue;
      final record = entry.value;
      result.add(
        StoredRecord(
          domain: entry.key.domain,
          key: entry.key.key,
          field: entry.key.field,
          version: record.version,
          deletedVersion: record.deletedVersion,
          data: record.data,
        ),
      );
    }
    return result;
  }

  @override
  Future<Iterable<StoredClear>> dumpClears({Set<String>? domains}) async {
    final result = <StoredClear>[];
    for (final entry in _clears.entries) {
      if (domains != null && !domains.contains(entry.key)) continue;
      result.add(StoredClear(domain: entry.key, cutoff: entry.value));
    }
    return result;
  }

  @override
  Future<SyncApplyStats> applySnapshot(
    ParsedSnapshot snapshot, {
    required Set<String> enabledDomains,
  }) async {
    _checkOpen();
    applySnapshotCalls++;
    final stats = _MutableStats();

    for (final entry in snapshot.clears.entries) {
      if (!enabledDomains.contains(entry.key)) continue;
      clock.observe(entry.value.hlc);
      final previous = _clears[entry.key];
      if (previous == null || entry.value > previous) {
        _clears[entry.key] = entry.value;
        stats.applied++;
      } else if (entry.value == previous) {
        stats.duplicates++;
      } else {
        stats.stale++;
      }
    }

    for (final record in snapshot.records) {
      if (!enabledDomains.contains(record.domain)) continue;
      clock.observe(record.version.hlc);
      final key = _RecKey(record.domain, record.key, record.field);
      final existing = _records[key];
      if (existing == null) {
        _records[key] = _Rec(
          version: record.version,
          deletedVersion: record.deletedVersion,
          data: record.data,
        );
        stats.applied++;
        continue;
      }
      var changed = false;
      if (record.version > existing.version) {
        existing.version = record.version;
        if (record.data != null) existing.data = record.data;
        changed = true;
      }
      final deleted = record.deletedVersion;
      if (deleted != null) {
        clock.observe(deleted.hlc);
        final currentDeleted = existing.deletedVersion;
        if (currentDeleted == null || deleted > currentDeleted) {
          existing.deletedVersion = deleted;
          changed = true;
        }
      }
      // Snapshot application never deletes records merely because they are
      // absent from the snapshot (§6.2).
      if (changed) {
        stats.applied++;
      } else {
        stats.duplicates++;
      }
    }

    for (final entry in snapshot.info.applied.entries) {
      final current = _applied[entry.key] ?? 0;
      if (entry.value > current) _applied[entry.key] = entry.value;
    }
    return stats.build();
  }

  @override
  Future<Map<String, int>> getApplied() async => Map<String, int>.of(_applied);

  @override
  Future<int> getAppliedSeq(String deviceId) async => _applied[deviceId] ?? 0;

  @override
  Future<void> setApplied(String deviceId, int seq) async {
    _checkOpen();
    if (seq > (_applied[deviceId] ?? 0)) _applied[deviceId] = seq;
  }

  @override
  Future<List<Map<String, Object?>>> getRecentConflicts({
    int limit = 50,
  }) async => const [];

  @override
  Future<void> clearConflicts() async {}

  @override
  Future<String?> getMeta(String key) async => _engineMeta[key];

  @override
  Future<void> setMeta(String key, String? value) async {
    if (value == null) {
      _engineMeta.remove(key);
    } else {
      _engineMeta[key] = value;
    }
  }

  @override
  Future<SnapshotInfo?> getLastSnapshot() async => _lastSnapshot;

  @override
  Future<void> setLastSnapshot(SnapshotInfo info) async {
    _lastSnapshot = info;
  }

  @override
  Future<Hlc> tickHlcForMeta() async => clock.tick();

  @override
  Future<Version?> versionOf(String domain, SyncKey key, String field) async =>
      _records[_RecKey(domain, key, field)]?.version;

  @override
  Future<StoredRecord?> recordOf(
    String domain,
    SyncKey key,
    String field,
  ) async {
    final record = _records[_RecKey(domain, key, field)];
    if (record == null) return null;
    return StoredRecord(
      domain: domain,
      key: key,
      field: field,
      version: record.version,
      deletedVersion: record.deletedVersion,
      data: record.data,
    );
  }

  /// Canonical view of every merged record + clear cutoff, used to assert
  /// convergence between two stores.
  Map<String, String> fingerprint() {
    final result = <String, String>{};
    final keys = _records.keys.toList()
      ..sort((a, b) {
        var comparison = a.domain.compareTo(b.domain);
        if (comparison != 0) return comparison;
        comparison = a.key.compareTo(b.key);
        if (comparison != 0) return comparison;
        return a.field.compareTo(b.field);
      });
    for (final key in keys) {
      final record = _records[key]!;
      result['${key.domain}|${key.key.encode()}|${key.field}'] =
          'v:${record.version}|d:${record.deletedVersion}'
          '|data:${_canonicalData(record.data)}';
    }
    final clearDomains = _clears.keys.toList()..sort();
    for (final domain in clearDomains) {
      result['clear|$domain'] = _clears[domain].toString();
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// In-test SyncTransport double
// ---------------------------------------------------------------------------

String _rangeKey(int lo, int hi) => '$lo-$hi';

({int lo, int hi}) _parseRange(String key) {
  final separator = key.indexOf('-');
  return (
    lo: int.parse(key.substring(0, separator)),
    hi: int.parse(key.substring(separator + 1)),
  );
}

/// In-memory [SyncTransport] with fault injection.
class _FakeTransport implements SyncTransport {
  final Map<String, RemoteState> states = <String, RemoteState>{};
  final Map<String, Map<String, Uint8List>> changes =
      <String, Map<String, Uint8List>>{};
  final Map<String, Uint8List> snapshots = <String, Uint8List>{};
  final Map<String, Map<String, Uint8List>> blobs =
      <String, Map<String, Uint8List>>{};
  final Set<String> devices = <String>{};

  // Fault injection knobs.
  bool failWriteChanges = false;
  bool failWriteState = false;
  bool failWriteSnapshot = false;
  bool failReadChanges = false;
  final Set<int> failWriteChangesCalls = <int>{};
  final Set<String> corruptStateDevices = <String>{};
  final Set<String> corruptChangeFiles = <String>{};

  int writeChangesCallCount = 0;
  int writeStateCallCount = 0;
  bool closed = false;

  // --- helpers for tests ----------------------------------------------------
  void addDevice(String deviceId) => devices.add(deviceId);

  Uint8List? changeBytes(String deviceId, int lo, int hi) =>
      changes[deviceId]?[_rangeKey(lo, hi)];

  void removeChange(String deviceId, int lo, int hi) {
    changes[deviceId]?.remove(_rangeKey(lo, hi));
  }

  void corruptChange(String deviceId, int lo, int hi) {
    corruptChangeFiles.add('$deviceId/${_rangeKey(lo, hi)}');
  }

  void corruptSnapshot(String deviceId) {
    snapshots[deviceId] = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
  }

  Uint8List? snapshotBytes(String deviceId) => snapshots[deviceId];

  @override
  Future<List<RemoteDeviceInfo>> listDevices() async {
    final ids = <String>{
      ...devices,
      ...states.keys,
      ...changes.keys,
      ...snapshots.keys,
    }.toList()..sort();
    return <RemoteDeviceInfo>[
      for (final deviceId in ids) RemoteDeviceInfo(deviceId: deviceId),
    ];
  }

  @override
  Future<RemoteState?> readState(String deviceId) async {
    if (corruptStateDevices.contains(deviceId)) {
      throw SyncTransportException('corrupt state for $deviceId');
    }
    return states[deviceId];
  }

  @override
  Future<List<ChangeRange>> listChanges(String deviceId) async {
    final files = changes[deviceId];
    if (files == null) return const <ChangeRange>[];
    final ranges = <ChangeRange>[
      for (final key in files.keys)
        ChangeRange(lo: _parseRange(key).lo, hi: _parseRange(key).hi),
    ]..sort((a, b) => a.lo.compareTo(b.lo));
    return ranges;
  }

  @override
  Future<Uint8List?> readChanges(String deviceId, ChangeRange range) async {
    if (failReadChanges) {
      throw SyncTransportException('readChanges failed for $deviceId');
    }
    final key = _rangeKey(range.lo, range.hi);
    if (corruptChangeFiles.contains('$deviceId/$key')) {
      return Uint8List.fromList(<int>[9, 9, 9]);
    }
    return changes[deviceId]?[key];
  }

  @override
  Future<Uint8List?> readSnapshot(String deviceId) async => snapshots[deviceId];

  @override
  Future<SnapshotInfo?> readSnapshotInfo(String deviceId) async {
    final bytes = snapshots[deviceId];
    if (bytes == null) return null;
    try {
      final raw = GZipCodec().decode(bytes);
      final text = utf8.decode(raw);
      final lines = text.split('\n').where((line) => line.trim().isNotEmpty);
      if (lines.isEmpty) return null;
      final decoded = jsonDecode(lines.first);
      if (decoded is! Map) return null;
      return SnapshotInfo.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeChanges(
    String deviceId,
    int lo,
    int hi,
    Uint8List bytes,
  ) async {
    writeChangesCallCount++;
    if (failWriteChanges ||
        failWriteChangesCalls.contains(writeChangesCallCount)) {
      throw SyncTransportException('writeChanges failed for $deviceId');
    }
    devices.add(deviceId);
    changes.putIfAbsent(
      deviceId,
      () => <String, Uint8List>{},
    )[_rangeKey(lo, hi)] = bytes;
  }

  @override
  Future<void> writeState(String deviceId, RemoteState state) async {
    writeStateCallCount++;
    if (failWriteState) {
      throw SyncTransportException('writeState failed for $deviceId');
    }
    devices.add(deviceId);
    states[deviceId] = state;
  }

  @override
  Future<void> writeSnapshot(String deviceId, Uint8List bytes) async {
    if (failWriteSnapshot) {
      throw SyncTransportException('writeSnapshot failed for $deviceId');
    }
    devices.add(deviceId);
    snapshots[deviceId] = bytes;
  }

  @override
  Future<void> writeBlob(
    String deviceId,
    String sha256,
    Uint8List bytes,
  ) async {
    blobs.putIfAbsent(deviceId, () => <String, Uint8List>{})[sha256] = bytes;
  }

  @override
  Future<Uint8List?> readBlob(String deviceId, String sha256) async =>
      blobs[deviceId]?[sha256];

  @override
  Future<bool> blobExists(String deviceId, String sha256) async =>
      blobs[deviceId]?.containsKey(sha256) ?? false;

  @override
  Future<List<String>> listBlobs(String deviceId) async {
    final names = blobs[deviceId]?.keys.toList() ?? const <String>[];
    return List<String>.of(names..sort());
  }

  @override
  Future<void> deleteBlob(String deviceId, String sha256) async {
    blobs[deviceId]?.remove(sha256);
  }

  @override
  Future<void> deleteChanges(String deviceId, int upToSeq) async {
    final files = changes[deviceId];
    if (files == null) return;
    files.removeWhere((key, _) => _parseRange(key).hi <= upToSeq);
  }

  @override
  Future<void> deleteDevice(String deviceId) async {
    devices.remove(deviceId);
    states.remove(deviceId);
    changes.remove(deviceId);
    snapshots.remove(deviceId);
    blobs.remove(deviceId);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

// ---------------------------------------------------------------------------
// Test fixture helpers
// ---------------------------------------------------------------------------

class _Fixture {
  _Fixture() {
    engineA = SyncEngine(store: storeA, transport: transport);
    engineB = SyncEngine(store: storeB, transport: transport);
  }

  final _FakeTransport transport = _FakeTransport();
  final _MemStore storeA = _MemStore(_deviceA);
  final _MemStore storeB = _MemStore(_deviceB);
  late final SyncEngine engineA;
  late final SyncEngine engineB;

  Future<void> init() async {
    await engineA.init();
    await engineB.init();
  }
}

SyncKey _historyKey(String comicId) => SyncKeys.historyKey(comicId, '1');

SyncKey _readLaterKey(String comicId) => SyncKeys.readLaterKey(comicId, '1');

Future<void> _emitProgress(_MemStore store, String comicId, int ep) async {
  await store.emit(
    domain: SyncDomains.history,
    key: _historyKey(comicId),
    field: SyncFields.progress,
    kind: SyncOpKind.upsert,
    data: <String, Object?>{'ep': ep, 'page': 1},
  );
}

void main() {
  group('push', () {
    test(
      'uploads pending ops, trims the outbox and writes remote state',
      () async {
        final fixture = _Fixture();
        await fixture.init();

        await _emitProgress(fixture.storeA, _comic1, 3);
        await fixture.storeA.emit(
          domain: SyncDomains.readLater,
          key: _readLaterKey(_comic1),
          kind: SyncOpKind.add,
        );

        final push = await fixture.engineA.push();
        expect(push.success, isTrue);
        expect(push.batches, 1);
        expect(push.opsPushed, 2);
        expect(push.lo, 1);
        expect(push.hi, 2);
        expect(push.lastPush, 2);
        expect(push.stateWritten, isTrue);
        expect(await fixture.storeA.pendingCount(), 0);

        final bytes = fixture.transport.changeBytes(_deviceA, 1, 2);
        expect(bytes, isNotNull);
        final decoded = SyncOpCodec.decode(
          bytes!,
          expectedDeviceId: _deviceA,
          lo: 1,
          hi: 2,
        );
        expect(decoded.map((op) => op.seq), <int>[1, 2]);

        final state = fixture.transport.states[_deviceA];
        expect(state, isNotNull);
        expect(state!.deviceId, _deviceA);
        expect(state.lastChange, 2);
        expect(state.applied[_deviceA], 2);
        expect(state.snapshot, isNull);

        // Nothing left to push: no extra change file, no spurious state write.
        final stateWrites = fixture.transport.writeStateCallCount;
        final noop = await fixture.engineA.push();
        expect(noop.success, isTrue);
        expect(noop.opsPushed, 0);
        expect(fixture.transport.writeStateCallCount, stateWrites);
      },
    );

    test('leaves the outbox intact when writeChanges fails, then retries the '
        'same range', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);

      fixture.transport.failWriteChanges = true;
      final failed = await fixture.engineA.push();
      expect(failed.success, isFalse);
      expect(failed.error, isNotNull);
      expect(failed.opsPushed, 0);
      expect(await fixture.storeA.pendingCount(), 2);
      expect(await fixture.storeA.getLastPush(), 0);
      expect(fixture.transport.changeBytes(_deviceA, 1, 2), isNull);
      expect(fixture.transport.states[_deviceA], isNull);

      fixture.transport.failWriteChanges = false;
      final retried = await fixture.engineA.push();
      expect(retried.success, isTrue);
      expect(retried.lo, 1);
      expect(retried.hi, 2);
      expect(retried.opsPushed, 2);
      expect(retried.batches, 1);
      expect(await fixture.storeA.pendingCount(), 0);
      expect(await fixture.storeA.getLastPush(), 2);

      final decoded = SyncOpCodec.decode(
        fixture.transport.changeBytes(_deviceA, 1, 2)!,
        expectedDeviceId: _deviceA,
        lo: 1,
        hi: 2,
      );
      // The retry re-encoded the very same contiguous range.
      expect(decoded.map((op) => op.seq), <int>[1, 2]);
      expect(fixture.transport.states[_deviceA]!.lastChange, 2);
    });

    test('a failed later batch keeps only the remaining ops pending', () async {
      final fixture = _Fixture();
      final engine = SyncEngine(
        store: fixture.storeA,
        transport: fixture.transport,
        pushBatchSize: 2,
      );
      await engine.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);
      await _emitProgress(fixture.storeA, _comic3, 3);

      fixture.transport.failWriteChangesCalls.add(2); // fail the second batch
      final push = await engine.push();
      expect(push.success, isFalse);
      expect(push.batches, 1);
      expect(push.opsPushed, 2);
      expect(fixture.transport.changeBytes(_deviceA, 1, 2), isNotNull);
      expect(await fixture.storeA.pendingCount(), 1);

      fixture.transport.failWriteChangesCalls.clear();
      final retry = await engine.push();
      expect(retry.success, isTrue);
      expect(retry.lo, 3);
      expect(retry.hi, 3);
      expect(retry.opsPushed, 1);
      expect(await fixture.storeA.pendingCount(), 0);
      expect(fixture.transport.states[_deviceA]!.lastChange, 3);
    });

    test(
      'state write failure is not a push failure and is retried later',
      () async {
        final fixture = _Fixture();
        await fixture.init();
        await _emitProgress(fixture.storeA, _comic1, 7);

        fixture.transport.failWriteState = true;
        final push = await fixture.engineA.push();
        expect(push.success, isTrue);
        expect(push.opsPushed, 1);
        expect(push.stateWritten, isFalse);
        expect(push.stateError, isNotNull);
        // Data is already delivered even without the state hint.
        expect(fixture.transport.changeBytes(_deviceA, 1, 1), isNotNull);
        expect(fixture.transport.states[_deviceA], isNull);

        fixture.transport.failWriteState = false;
        final retry = await fixture.engineA.push();
        expect(retry.success, isTrue);
        expect(retry.opsPushed, 0);
        expect(retry.stateWritten, isTrue);
        expect(fixture.transport.states[_deviceA], isNotNull);
        expect(fixture.transport.states[_deviceA]!.lastChange, 1);
      },
    );
  });

  group('pull', () {
    test('push/pull roundtrip between two devices', () async {
      final fixture = _Fixture();
      await fixture.init();

      await _emitProgress(fixture.storeA, _comic1, 3);
      await fixture.storeA.emit(
        domain: SyncDomains.readLater,
        key: _readLaterKey(_comic1),
        kind: SyncOpKind.add,
      );
      expect((await fixture.engineA.push()).success, isTrue);

      final pullB = await fixture.engineB.pull();
      expect(pullB.success, isTrue, reason: pullB.errors.join('\n'));
      expect(pullB.devicesInspected, 1);
      expect(pullB.rangesRead, 1);
      expect(pullB.opsApplied, 2);
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 2);

      final history = await fixture.storeB.recordOf(
        SyncDomains.history,
        _historyKey(_comic1),
        SyncFields.progress,
      );
      expect(history, isNotNull);
      expect(history!.data, <String, Object?>{'ep': 3, 'page': 1});
      final readLater = await fixture.storeB.recordOf(
        SyncDomains.readLater,
        _readLaterKey(_comic1),
        SyncFields.empty,
      );
      expect(readLater, isNotNull);
      expect(readLater!.version, isNotNull);

      // B writes its own data, A pulls it back.
      await fixture.storeB.emit(
        domain: SyncDomains.setting,
        key: SyncKeys.settingKey('theme'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'dark'},
      );
      expect((await fixture.engineB.push()).success, isTrue);
      expect(fixture.transport.states[_deviceB]!.lastChange, 1);

      final pullA = await fixture.engineA.pull();
      expect(pullA.success, isTrue, reason: pullA.errors.join('\n'));
      expect(pullA.opsApplied, 1);
      expect(await fixture.storeA.getAppliedSeq(_deviceB), 1);
      final theme = await fixture.storeA.recordOf(
        SyncDomains.setting,
        SyncKeys.settingKey('theme'),
        SyncFields.empty,
      );
      expect(theme, isNotNull);
      expect(theme!.data, <String, Object?>{'value': 'dark'});

      // Second pull is a no-op.
      final again = await fixture.engineB.pull();
      expect(again.success, isTrue);
      expect(again.opsApplied, 0);
      expect(again.devicesAdvanced, 0);
    });

    test('interleaved edits on both devices converge', () async {
      final fixture = _Fixture();
      await fixture.init();

      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeB, _comic1, 2);
      await fixture.storeA.emit(
        domain: SyncDomains.readLater,
        key: _readLaterKey(_comic1),
        kind: SyncOpKind.add,
      );
      await fixture.storeB.emit(
        domain: SyncDomains.readLater,
        key: _readLaterKey(_comic1),
        kind: SyncOpKind.add,
      );

      expect((await fixture.engineA.push()).success, isTrue);
      expect((await fixture.engineB.push()).success, isTrue);
      expect((await fixture.engineA.pull()).success, isTrue);
      expect((await fixture.engineB.pull()).success, isTrue);
      // A second round settles any state-hint ordering.
      expect((await fixture.engineA.pull()).success, isTrue);
      expect((await fixture.engineB.pull()).success, isTrue);

      expect(
        fixture.storeA.fingerprint(),
        equals(fixture.storeB.fingerprint()),
      );

      // Both devices used the same fixed wall clock, so the HLC tie is broken
      // by device id: _deviceB > _deviceA, regardless of apply order.
      final history = await fixture.storeA.recordOf(
        SyncDomains.history,
        _historyKey(_comic1),
        SyncFields.progress,
      );
      expect(history, isNotNull);
      expect(history!.data, <String, Object?>{'ep': 2, 'page': 1});
    });

    test('corrupt state is tolerated via the change listing', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      expect((await fixture.engineA.push()).success, isTrue);

      fixture.transport.corruptStateDevices.add(_deviceA);
      final pull = await fixture.engineB.pull();
      expect(pull.success, isTrue, reason: pull.errors.join('\n'));
      expect(pull.warnings, isNotEmpty);
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 1);
      expect(
        (await fixture.storeB.recordOf(
          SyncDomains.history,
          _historyKey(_comic1),
          SyncFields.progress,
        ))!.data,
        <String, Object?>{'ep': 1, 'page': 1},
      );
    });

    test('missing state document still synchronizes', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);
      expect((await fixture.engineA.push()).success, isTrue);
      fixture.transport.states.remove(_deviceA);

      final pull = await fixture.engineB.pull();
      expect(pull.success, isTrue, reason: pull.errors.join('\n'));
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 2);
      expect(
        fixture.storeB.fingerprint(),
        equals(fixture.storeA.fingerprint()),
      );
    });

    test('empty and malformed remote devices are skipped', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      expect((await fixture.engineA.push()).success, isTrue);

      fixture.transport
        ..addDevice(_deviceC)
        ..addDevice('NOT-A-VALID-DEVICE-ID');

      final pull = await fixture.engineB.pull();
      expect(pull.success, isTrue, reason: pull.errors.join('\n'));
      expect(pull.opsApplied, 1);
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 1);
    });

    test(
      'disabled and unknown domains are skipped but advance the watermark',
      () async {
        final fixture = _Fixture();
        final engineFiltered = SyncEngine(
          store: fixture.storeB,
          transport: fixture.transport,
          enabledDomains: <String>{SyncDomains.history},
        );
        await fixture.engineA.init();
        await engineFiltered.init();

        await _emitProgress(fixture.storeA, _comic1, 5);
        await fixture.storeA.emit(
          domain: SyncDomains.setting,
          key: SyncKeys.settingKey('theme'),
          kind: SyncOpKind.upsert,
          data: <String, Object?>{'value': 'dark'},
        );
        await fixture.storeA.emit(
          domain: 'futureDomain',
          key: SyncKeys.settingKey('something'),
          kind: SyncOpKind.upsert,
          data: <String, Object?>{'value': 1},
        );
        expect((await fixture.engineA.push()).opsPushed, 3);

        final pull = await engineFiltered.pull();
        expect(pull.success, isTrue, reason: pull.errors.join('\n'));
        // The watermark advanced past filtered ops even though they were not
        // applied (§7.3 merge transaction).
        expect(await fixture.storeB.getAppliedSeq(_deviceA), 3);
        expect(pull.opsSkipped, 2);
        // The store was only given enabled-domain ops.
        expect(
          fixture.storeB.lastApplyOpsBatch.every(
            (op) => op.domain == SyncDomains.history,
          ),
          isTrue,
        );
        expect(
          await fixture.storeB.recordOf(
            SyncDomains.setting,
            SyncKeys.settingKey('theme'),
            SyncFields.empty,
          ),
          isNull,
        );
        expect(
          await fixture.storeB.recordOf(
            'futureDomain',
            SyncKeys.settingKey('something'),
            SyncFields.empty,
          ),
          isNull,
        );
        expect(
          (await fixture.storeB.recordOf(
            SyncDomains.history,
            _historyKey(_comic1),
            SyncFields.progress,
          ))!.data,
          <String, Object?>{'ep': 5, 'page': 1},
        );
      },
    );
  });

  group('bootstrap / gap repair', () {
    test('gap after change GC is repaired from the snapshot', () async {
      final fixture = _Fixture();
      await fixture.init();
      for (var index = 1; index <= 3; index++) {
        await _emitProgress(fixture.storeA, 'comic-$index', index);
      }
      expect((await fixture.engineA.push()).opsPushed, 3);

      final snapshot = await fixture.engineA.snapshot();
      expect(snapshot.success, isTrue, reason: '$snapshot');
      expect(snapshot.info!.applied[_deviceA], 3);
      expect(snapshot.info!.rangeHi, 3);

      final gc = await fixture.engineA.gc();
      expect(gc.deleted, isTrue);
      expect(gc.deletedUpTo, 3);
      expect(await fixture.transport.listChanges(_deviceA), isEmpty);

      final pull = await fixture.engineB.pull();
      expect(pull.success, isTrue, reason: pull.errors.join('\n'));
      expect(pull.snapshotsApplied, greaterThanOrEqualTo(1));
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 3);
      expect(
        fixture.storeB.fingerprint(),
        equals(fixture.storeA.fingerprint()),
      );

      // Idempotent: a second pull changes nothing.
      final again = await fixture.engineB.pull();
      expect(again.success, isTrue);
      expect(again.opsApplied, 0);
      expect(
        fixture.storeB.fingerprint(),
        equals(fixture.storeA.fingerprint()),
      );
    });

    test('corrupt change file is repaired from the snapshot', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);
      expect((await fixture.engineA.push()).opsPushed, 2);
      expect((await fixture.engineA.snapshot()).success, isTrue);
      fixture.transport.corruptChange(_deviceA, 1, 2);

      final pull = await fixture.engineB.pull();
      expect(pull.success, isTrue, reason: pull.errors.join('\n'));
      expect(pull.snapshotsApplied, greaterThanOrEqualTo(1));
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 2);
      expect(
        fixture.storeB.fingerprint(),
        equals(fixture.storeA.fingerprint()),
      );
    });

    test(
      'bootstrap finds a snapshot when the state document is missing',
      () async {
        final fixture = _Fixture();
        await fixture.init();
        await _emitProgress(fixture.storeA, _comic1, 1);
        await _emitProgress(fixture.storeA, _comic2, 2);
        expect((await fixture.engineA.push()).opsPushed, 2);
        expect((await fixture.engineA.snapshot()).success, isTrue);
        expect((await fixture.engineA.gc()).deleted, isTrue);
        fixture.transport.states.remove(_deviceA);

        final pull = await fixture.engineB.pull();
        expect(pull.success, isTrue, reason: pull.errors.join('\n'));
        expect(pull.snapshotsApplied, greaterThanOrEqualTo(1));
        expect(await fixture.storeB.getAppliedSeq(_deviceA), 2);
        expect(
          fixture.storeB.fingerprint(),
          equals(fixture.storeA.fingerprint()),
        );
      },
    );

    test(
      'corrupt snapshot cannot corrupt local state and the gap is reported',
      () async {
        final fixture = _Fixture();
        await fixture.init();
        await _emitProgress(fixture.storeA, _comic1, 1);
        expect((await fixture.engineA.push()).opsPushed, 1);
        expect((await fixture.engineA.snapshot()).success, isTrue);
        fixture.transport
          ..corruptSnapshot(_deviceA)
          ..removeChange(_deviceA, 1, 1);

        final pull = await fixture.engineB.pull();
        expect(pull.success, isFalse);
        expect(pull.snapshotsApplied, 0);
        expect(await fixture.storeB.getAppliedSeq(_deviceA), 0);
        expect(fixture.storeB.isEmpty, isTrue);
      },
    );

    test(
      'public bootstrap is idempotent and keeps partial local data',
      () async {
        final fixture = _Fixture();
        await fixture.init();
        await _emitProgress(fixture.storeA, _comic1, 1);
        await fixture.storeA.emit(
          domain: SyncDomains.readLater,
          key: _readLaterKey(_comic2),
          kind: SyncOpKind.add,
        );
        expect((await fixture.engineA.push()).opsPushed, 2);
        expect((await fixture.engineA.snapshot()).success, isTrue);

        // B already has unrelated local data that must survive the bootstrap.
        await fixture.storeB.emit(
          domain: SyncDomains.readLater,
          key: _readLaterKey(_comic3),
          kind: SyncOpKind.add,
        );

        final first = await fixture.engineB.bootstrap();
        expect(first.success, isTrue, reason: '${first.error}');
        expect(first.snapshotsApplied, greaterThanOrEqualTo(1));
        expect(first.pull!.success, isTrue);
        expect(await fixture.storeB.getAppliedSeq(_deviceA), 2);
        final afterFirst = fixture.storeB.fingerprint();

        final second = await fixture.engineB.bootstrap();
        expect(second.success, isTrue);
        expect(fixture.storeB.fingerprint(), equals(afterFirst));
        // Local-only data is preserved: bootstrap is a merge, not a replace
        // (§7.4 step 6).
        expect(
          await fixture.storeB.recordOf(
            SyncDomains.readLater,
            _readLaterKey(_comic3),
            SyncFields.empty,
          ),
          isNotNull,
        );
      },
    );
  });

  group('snapshot', () {
    test('periodic snapshot uses lastPush, compaction uses nextSeq', () async {
      final fixture = _Fixture();
      final compactEngine = SyncEngine(
        store: fixture.storeA,
        transport: fixture.transport,
        compactionPendingThreshold: 1,
      );
      await fixture.init();
      await compactEngine.init();

      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);
      await _emitProgress(fixture.storeA, _comic3, 3);
      expect((await fixture.engineA.push()).opsPushed, 3);
      // Pending, not yet uploaded ops: nextSeq is ahead of lastPush.
      await _emitProgress(fixture.storeA, _comic4, 4);
      await _emitProgress(fixture.storeA, _comic5, 5);
      expect(await fixture.storeA.getNextSeq(), 5);
      expect(await fixture.storeA.getLastPush(), 3);

      final periodic = await fixture.engineA.snapshot();
      expect(periodic.success, isTrue, reason: '$periodic');
      expect(periodic.info!.rangeLo, 1);
      expect(periodic.info!.rangeHi, 3);
      // CRITICAL (§7.2 step 6): applied[self] must be lastPush, never nextSeq.
      expect(periodic.info!.applied[_deviceA], 3);
      expect(periodic.info!.applied[_deviceA], isNot(5));
      expect(periodic.info!.domains, contains(SyncDomains.history));
      expect(periodic.records, greaterThanOrEqualTo(3));

      final remoteState = fixture.transport.states[_deviceA]!;
      expect(remoteState.snapshot, isNotNull);
      expect(remoteState.snapshot!.applied[_deviceA], 3);
      expect(remoteState.snapshot!.rangeHi, 3);

      // B only sees the three delivered changes.
      final pull = await fixture.engineB.pull();
      expect(pull.success, isTrue, reason: pull.errors.join('\n'));
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 3);
      expect(
        await fixture.storeB.recordOf(
          SyncDomains.history,
          _historyKey(_comic5),
          SyncFields.progress,
        ),
        isNull,
      );

      // Compaction replaces the pending changes with the snapshot.
      final compact = await compactEngine.compactSnapshotIfNeeded();
      expect(compact.success, isTrue, reason: '$compact');
      expect(compact.info!.applied[_deviceA], 5);
      expect(compact.info!.rangeHi, 5);
      expect(compact.stateWritten, isTrue);
      expect(await fixture.storeA.pendingCount(), 0);
      expect(await fixture.storeA.getLastPush(), 5);
      // lastChange still reports the last change file that was delivered.
      expect(fixture.transport.states[_deviceA]!.lastChange, 3);
      expect(
        fixture.transport.states[_deviceA]!.snapshot!.applied[_deviceA],
        5,
      );

      // B repairs the now-missing seqs 4..5 through the compaction snapshot.
      final pull2 = await fixture.engineB.pull();
      expect(pull2.success, isTrue, reason: pull2.errors.join('\n'));
      expect(pull2.snapshotsApplied, greaterThanOrEqualTo(1));
      expect(await fixture.storeB.getAppliedSeq(_deviceA), 5);
      expect(
        fixture.storeB.fingerprint(),
        equals(fixture.storeA.fingerprint()),
      );
    });

    test('maybeSnapshot respects the interval and change threshold', () async {
      final fixture = _Fixture();
      final intervalEngine = SyncEngine(
        store: fixture.storeA,
        transport: fixture.transport,
        snapshotChangeThreshold: 1,
        snapshotInterval: const Duration(days: 1),
      );
      await intervalEngine.init();

      // First call seeds a snapshot (no snapshot exists yet).
      final initial = await intervalEngine.maybeSnapshot();
      expect(initial.success, isTrue);
      expect(initial.info, isNotNull);

      final skipped = await intervalEngine.maybeSnapshot();
      expect(skipped.skipped, isTrue);

      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);
      expect((await intervalEngine.push()).opsPushed, 2);
      final due = await intervalEngine.maybeSnapshot();
      expect(due.skipped, isFalse);
      expect(due.info!.applied[_deviceA], 2);
    });

    test(
      'gc is a no-op without a snapshot and status reports diagnostics',
      () async {
        final fixture = _Fixture();
        await fixture.init();
        await _emitProgress(fixture.storeA, _comic1, 1);
        expect((await fixture.engineA.push()).success, isTrue);

        final gcBefore = await fixture.engineA.gc();
        expect(gcBefore.skipped, isTrue);
        expect(gcBefore.deleted, isFalse);

        final status = await fixture.engineA.status();
        expect(status.localDeviceId, _deviceA);
        expect(status.lastPush, 1);
        expect(status.pendingOps, 0);
        expect(status.lastSnapshot, isNull);
        expect(
          status.enabledDomains.toList()..sort(),
          SyncDomains.all.toList()..sort(),
        );
        expect(status.stateDirty, isFalse);
        expect(status.protocolVersion, syncProtocolVersionTag);
        expect(status.applied, isEmpty);

        expect((await fixture.engineA.snapshot()).success, isTrue);
        final gcAfter = await fixture.engineA.gc();
        expect(gcAfter.deleted, isTrue);
        expect(gcAfter.deletedUpTo, 1);
        expect(await fixture.transport.listChanges(_deviceA), isEmpty);
      },
    );
  });

  group('syncOnce', () {
    test('pull then push then snapshot in one cycle', () async {
      final fixture = _Fixture();
      final engineA = SyncEngine(
        store: fixture.storeA,
        transport: fixture.transport,
        pushBatchSize: 1,
      );
      await engineA.init();
      await fixture.engineB.init();

      // Seed remote data from B.
      await fixture.storeB.emit(
        domain: SyncDomains.setting,
        key: SyncKeys.settingKey('pageMode'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'scroll'},
      );
      expect((await fixture.engineB.push()).success, isTrue);

      await _emitProgress(fixture.storeA, _comic1, 9);
      await _emitProgress(fixture.storeA, _comic2, 10);

      final result = await engineA.syncOnce();
      expect(
        result.pull.success,
        isTrue,
        reason: result.pull.errors.join('\n'),
      );
      expect(result.pull.opsApplied, 1);
      expect(result.push.success, isTrue);
      expect(result.push.opsPushed, 2);
      expect(result.snapshot.success, isTrue);
      expect(result.snapshot.info!.applied[_deviceA], 2);
      expect(await fixture.storeA.getAppliedSeq(_deviceB), 1);
      expect(
        (await fixture.storeA.recordOf(
          SyncDomains.setting,
          SyncKeys.settingKey('pageMode'),
          SyncFields.empty,
        ))!.data,
        <String, Object?>{'value': 'scroll'},
      );
      expect(fixture.transport.states[_deviceA]!.lastChange, 2);
    });
  });

  group('M2 replay / compaction recovery', () {
    test('replayDomain re-reads retained change files without advancing '
        'watermarks', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 5);
      await fixture.storeA.emit(
        domain: SyncDomains.readLater,
        key: _readLaterKey(_comic1),
        kind: SyncOpKind.add,
      );
      await fixture.engineA.push();

      final storeC = _MemStore(_deviceC);
      final engineC = SyncEngine(
        store: storeC,
        transport: fixture.transport,
        enabledDomains: SyncDomains.all,
      );
      await engineC.init();
      final replay = await engineC.replayDomain(SyncDomains.history);
      expect(replay.errors, isEmpty);
      expect(replay.opsApplied, greaterThanOrEqualTo(1));
      final record = await storeC.recordOf(
        SyncDomains.history,
        _historyKey(_comic1),
        SyncFields.progress,
      );
      expect(record, isNotNull);
      expect(record!.data!['ep'], 5);
      expect(await storeC.getAppliedSeq(_deviceA), 0);
      await storeC.close();
    });

    test(
      'replayDomain falls back to the snapshot when changes were pruned',
      () async {
        final fixture = _Fixture();
        await fixture.init();
        await _emitProgress(fixture.storeA, _comic2, 8);
        await fixture.engineA.push();
        await fixture.engineA.snapshot();
        await fixture.engineA.gc();

        final storeC = _MemStore(_deviceC);
        final engineC = SyncEngine(
          store: storeC,
          transport: fixture.transport,
          enabledDomains: SyncDomains.all,
        );
        await engineC.init();
        final replay = await engineC.replayDomain(SyncDomains.history);
        expect(replay.errors, isEmpty);
        final record = await storeC.recordOf(
          SyncDomains.history,
          _historyKey(_comic2),
          SyncFields.progress,
        );
        expect(record, isNotNull);
        expect(record!.data!['ep'], 8);
        expect(await storeC.getAppliedSeq(_deviceA), 0);
        await storeC.close();
      },
    );

    test('compaction marker is cleared after a successful compaction and '
        'recovery is safe', () async {
      final fixture = _Fixture();
      await fixture.init();
      await _emitProgress(fixture.storeA, _comic1, 1);
      await _emitProgress(fixture.storeA, _comic2, 2);
      final engine = SyncEngine(
        store: fixture.storeA,
        transport: fixture.transport,
        compactionPendingThreshold: 1,
      );
      await engine.init();
      final compact = await engine.compactSnapshotIfNeeded();
      expect(compact.skipped, isFalse);
      expect(await fixture.storeA.getMeta('pendingCompaction'), isNull);

      // Simulate a crash after the snapshot+state but before the outbox clear.
      await fixture.storeA.setMeta(
        'pendingCompaction',
        jsonEncode({
          'nextSeq': await fixture.storeA.getNextSeq(),
          'stage': 'state',
        }),
      );
      final recovered = await engine.recoverPendingCompaction();
      expect(recovered, isNotNull);
      expect(await fixture.storeA.getMeta('pendingCompaction'), isNull);
      expect(await engine.recoverPendingCompaction(), isNull);
    });
  });
}
