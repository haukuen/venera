import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/sync/hlc.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/snapshot.dart';
import 'package:venera/sync/sqlite_store.dart';
import 'package:venera/sync/store.dart';
import 'package:venera/sync/version.dart';

const _deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
const _deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';

const _history = 'history';
const _readLater = 'readLater';
const _progress = 'progress';

final _historyKey1 = SyncKey(const ['abc', '1']);
final _historyKey2 = SyncKey(const ['abc', '2']);

class _FakeTime {
  _FakeTime([int ms = 1762345678000])
    : _now = DateTime.fromMillisecondsSinceEpoch(ms);

  DateTime _now;

  DateTime now() => _now;

  void advance(int ms) {
    _now = _now.add(Duration(milliseconds: ms));
  }
}

SyncKey _key(String a, [String? b]) => SyncKey([a, if (b != null) b]);

SyncOp _remoteOp({
  String device = _deviceB,
  required int seq,
  required int ms,
  int counter = 0,
  SyncOpKind kind = SyncOpKind.upsert,
  String domain = _history,
  List<String> key = const ['abc', '1'],
  String field = _progress,
  Map<String, Object?>? data,
}) {
  return SyncOp(
    deviceId: device,
    seq: seq,
    version: Version(Hlc(ms: ms, counter: counter, deviceId: device), seq),
    domain: domain,
    key: kind == SyncOpKind.clear ? null : SyncKey(key),
    field: kind == SyncOpKind.clear ? '' : field,
    kind: kind,
    data: kind == SyncOpKind.clear ? null : data,
  );
}

void main() {
  late Directory dir;
  late _FakeTime time;
  late SqliteSyncStore store;
  late List<SqliteSyncStore> extraStores;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('venera-sync-store-');
    time = _FakeTime();
    extraStores = [];
    store = SqliteSyncStore(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceA,
      now: time.now,
    );
    await store.init();
  });

  tearDown(() async {
    for (final extra in extraStores) {
      await extra.close();
    }
    await store.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Schema / persistence
  // ---------------------------------------------------------------------------

  test(
    'init creates the sync schema with the app sqlite conventions',
    () async {
      await store.close();
      final db = sqlite3.open('${dir.path}/sync.db');
      try {
        final tables = db
            .select("SELECT name FROM sqlite_master WHERE type = 'table'")
            .map((row) => row['name'] as String)
            .toSet();
        expect(
          tables,
          containsAll([
            'sync_meta',
            'sync_outbox',
            'sync_applied',
            'sync_seen',
            'sync_reg',
            'sync_clear',
          ]),
        );
        final journalMode =
            db.select('PRAGMA journal_mode;').first['journal_mode'] as String;
        expect(journalMode.toLowerCase(), 'delete');

        final meta = {
          for (final row in db.select('SELECT key, value FROM sync_meta'))
            row['key'] as String: row['value'],
        };
        expect(meta['deviceId'], _deviceA);
        expect(meta['nextSeq'], '0');
        expect(meta['lastPush'], '0');
        expect(meta['hlcMs'], '0');
        expect(meta['hlcCounter'], '0');
        expect(meta['frozenUpTo'], '0');
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'counters, watermarks, outbox and snapshot info survive a restart',
    () async {
      final first = await store.emit(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 1},
      );
      final second = await store.emit(
        domain: _history,
        key: _historyKey2,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 2},
      );
      await store.emitClear(_readLater);
      await store.setApplied(_deviceB, 7);
      final snapshotInfo = SnapshotInfo(
        deviceId: _deviceA,
        hlc: await store.tickHlcForMeta(),
        rangeLo: 1,
        rangeHi: second.seq,
        applied: {_deviceA: second.seq},
        domains: {_history, _readLater},
      );
      await store.setLastSnapshot(snapshotInfo);
      final clockBefore = store.clock.last;

      await store.close();
      store = SqliteSyncStore(
        dbPath: '${dir.path}/sync.db',
        deviceId: _deviceA,
        now: time.now,
      );
      await store.init();

      expect(await store.getNextSeq(), 3);
      expect(await store.getLastPush(), 0);
      expect(await store.pendingCount(), 3);
      expect(await store.getAppliedSeq(_deviceB), 7);
      final restoredSnapshot = await store.getLastSnapshot();
      expect(restoredSnapshot, isNotNull);
      expect(restoredSnapshot!.deviceId, _deviceA);
      expect(restoredSnapshot.rangeHi, second.seq);
      expect(restoredSnapshot.domains, {_history, _readLater});
      expect(store.clock.last.compareTo(clockBefore), greaterThanOrEqualTo(0));

      final record = await store.recordOf(_history, _historyKey1, _progress);
      expect(record, isNotNull);
      expect(record!.data, {'page': 1});
      expect(record.version, first.version);

      // Re-emitting the same (d, k, f) after restart still coalesces into the
      // persisted pending row instead of allocating a new seq.
      final coalesced = await store.emit(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 9},
      );
      expect(coalesced.seq, first.seq);
      expect(await store.pendingCount(), 3);
    },
  );

  test('reopening with a different device id is rejected', () async {
    await store.close();
    final wrongDevice = SqliteSyncStore(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceB,
      now: time.now,
    );
    await expectLater(wrongDevice.init(), throwsStateError);
    await wrongDevice.close();

    store = SqliteSyncStore(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceA,
      now: time.now,
    );
    await store.init();
    expect(await store.pendingCount(), 0);
  });

  // ---------------------------------------------------------------------------
  // Emit / coalescing
  // ---------------------------------------------------------------------------

  test('emit coalesces in place and keeps pending seqs contiguous', () async {
    final first = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    expect(first.seq, 1);

    time.advance(5);
    final second = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 2},
    );
    expect(second.seq, 1);
    expect(second.version.compareTo(first.version), greaterThan(0));
    expect(await store.pendingCount(), 1);

    final third = await store.emit(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 3},
    );
    expect(third.seq, 2);

    final fourth = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 4},
    );
    expect(fourth.seq, 1);

    final pending = await store.pendingOps();
    expect(pending.map((op) => op.seq).toList(), [1, 2]);
    expect(pending.first.data, {'page': 4});
    expect(await store.getNextSeq(), 2);

    final record = await store.recordOf(_history, _historyKey1, _progress);
    expect(record, isNotNull);
    expect(record!.data, {'page': 4});
    expect(record.version, fourth.version);
    expect(record.visible, isTrue);
  });

  test('collection add/del coalesce to the final op', () async {
    final key = _historyKey1;
    final add = await store.emit(
      domain: _readLater,
      key: key,
      kind: SyncOpKind.add,
    );
    expect(add.seq, 1);
    var record = await store.recordOf(_readLater, key, '');
    expect(record, isNotNull);
    expect(record!.visible, isTrue);

    time.advance(1);
    final del = await store.emit(
      domain: _readLater,
      key: key,
      kind: SyncOpKind.del,
    );
    expect(del.seq, 1);
    expect(await store.pendingCount(), 1);
    record = await store.recordOf(_readLater, key, '');
    expect(record!.visible, isFalse);
    expect(record.deletedVersion, isNotNull);
    expect(record.deletedVersion!.compareTo(record.version), greaterThan(0));

    time.advance(1);
    final readded = await store.emit(
      domain: _readLater,
      key: key,
      kind: SyncOpKind.add,
    );
    expect(readded.seq, 1);
    record = await store.recordOf(_readLater, key, '');
    expect(record!.visible, isTrue);

    final pending = await store.pendingOps();
    expect(pending.single.kind, SyncOpKind.add);
    expect(pending.single.seq, 1);
  });

  test('clear cutoffs coalesce per domain and stay contiguous', () async {
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    final clear1 = await store.emitClear(_history);
    expect(clear1.seq, 2);
    time.advance(10);
    final clear2 = await store.emitClear(_history);
    expect(clear2.seq, 2);
    final other = await store.emitClear(_readLater);
    expect(other.seq, 3);

    expect(await store.pendingCount(), 3);
    final pending = await store.pendingOps();
    expect(pending.map((op) => op.seq).toList(), [1, 2, 3]);
    expect(pending[1].kind, SyncOpKind.clear);
    expect(pending[1].domain, _history);
    expect(pending[2].domain, _readLater);

    final clears = (await store.dumpClears()).toList();
    expect(clears.length, 2);
    final historyClear = clears.firstWhere((clear) => clear.domain == _history);
    expect(historyClear.cutoff, clear2.version);
  });

  test('many emits allocate monotonic HLCs and contiguous seqs', () async {
    final hlcs = <Hlc>[];
    final seqs = <int>[];
    for (var i = 0; i < 40; i++) {
      final op = await store.emit(
        domain: _history,
        key: _key('book', '$i'),
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': i},
      );
      seqs.add(op.seq);
      hlcs.add(op.version.hlc);
    }
    expect(seqs, List.generate(40, (index) => index + 1));
    for (var i = 1; i < hlcs.length; i++) {
      expect(hlcs[i].compareTo(hlcs[i - 1]), greaterThan(0));
    }
    expect(await store.getNextSeq(), 40);
    expect(await store.pendingCount(), 40);

    // Coalescing must not consume a seq.
    await store.emit(
      domain: _history,
      key: _key('book', '0'),
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 100},
    );
    expect(await store.getNextSeq(), 40);
    expect(await store.pendingCount(), 40);
  });

  test('after a push a fresh emit allocates a new seq', () async {
    final first = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    await store.markPushed(first.seq);
    final second = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 2},
    );
    expect(second.seq, first.seq + 1);
    expect(await store.pendingCount(), 1);
    expect(await store.getLastPush(), first.seq);
  });

  test(
    'pendingOps honours limit/maxBytes and returns consecutive seqs',
    () async {
      for (var i = 0; i < 5; i++) {
        await store.emit(
          domain: _history,
          key: _key('k', '$i'),
          field: _progress,
          kind: SyncOpKind.upsert,
          data: {'page': i},
        );
      }

      expect((await store.pendingOps(limit: 2)).map((op) => op.seq), [1, 2]);
      final small = await store.pendingOps(maxBytes: 1);
      expect(small.length, 1);
      expect(small.single.seq, 1);
      expect(await store.pendingOps(limit: 0), isEmpty);
      expect((await store.pendingOps(limit: 10)).map((op) => op.seq), [
        1,
        2,
        3,
        4,
        5,
      ]);
    },
  );

  test('markPushed deletes the uploaded prefix and never regresses', () async {
    for (var i = 0; i < 3; i++) {
      await store.emit(
        domain: _history,
        key: _key('k', '$i'),
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': i},
      );
    }

    await store.markPushed(2);
    expect(await store.getLastPush(), 2);
    expect(await store.pendingCount(), 1);
    expect((await store.pendingOps()).single.seq, 3);

    await store.markPushed(1);
    expect(await store.getLastPush(), 2);
    expect(await store.pendingCount(), 1);

    await store.markPushed(3);
    expect(await store.getLastPush(), 3);
    expect(await store.pendingCount(), 0);

    final next = await store.emit(
      domain: _history,
      key: _key('k', 'new'),
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 0},
    );
    expect(next.seq, 4);
  });

  // ---------------------------------------------------------------------------
  // Outbox freeze (upload race)
  // ---------------------------------------------------------------------------

  test(
    'pendingOps freezes its batch and later emits allocate new seqs',
    () async {
      final first = await store.emit(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 1},
      );
      expect(first.seq, 1);

      final frozenBatch = await store.pendingOps();
      expect(frozenBatch.map((op) => op.seq), [1]);
      final frozenHlc = frozenBatch.single.version.hlc;

      // Emitting the same (d, k, f) must append a new seq instead of rewriting
      // the frozen row that may already be in flight.
      time.advance(5);
      final second = await store.emit(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 2},
      );
      expect(second.seq, 2);

      final ops = await store.pendingOps();
      expect(ops.map((op) => op.seq), [1, 2]);
      expect(ops[0].data, {'page': 1});
      expect(ops[0].version.hlc, frozenHlc);
      expect(ops[1].data, {'page': 2});
      expect(await store.getNextSeq(), 2);

      // The merged local record still reflects the newest emit.
      final record = await store.recordOf(_history, _historyKey1, _progress);
      expect(record!.data, {'page': 2});
      expect(record.version, second.version);
    },
  );

  test('pendingOps is idempotent and returns identical frozen rows', () async {
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    await store.emit(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 2},
    );

    final firstRead = await store.pendingOps(limit: 1);
    final secondRead = await store.pendingOps(limit: 1);
    expect(
      secondRead.map((op) => op.toJson()),
      firstRead.map((op) => op.toJson()),
    );
    expect(firstRead.single.seq, 1);

    // A larger read returns the same frozen rows plus the rest of the suffix.
    final full = await store.pendingOps();
    expect(full.map((op) => op.seq), [1, 2]);
    expect(full.first.data, {'page': 1});
  });

  test('frozen marker survives a restart', () async {
    final first = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    await store.pendingOps();
    expect((await store.pendingOps()).single.version, first.version);

    await store.close();
    store = SqliteSyncStore(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceA,
      now: time.now,
    );
    await store.init();

    time.advance(5);
    final second = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 2},
    );
    expect(second.seq, 2);
    final ops = await store.pendingOps();
    expect(ops.map((op) => op.seq), [1, 2]);
    expect(ops.first.data, {'page': 1});
  });

  test('markPushed clears the freeze so coalescing resumes', () async {
    final first = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    await store.pendingOps();
    final second = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 2},
    );
    expect(second.seq, 2);

    // Acknowledging row 1 removes the freeze: row 2 is not in flight anymore.
    await store.markPushed(first.seq);
    time.advance(5);
    final third = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 3},
    );
    expect(third.seq, second.seq);
    expect(await store.pendingCount(), 1);

    final ops = await store.pendingOps();
    expect(ops.single.seq, second.seq);
    expect(ops.single.data, {'page': 3});
  });

  test('markPushed keeps the freeze for remaining in-flight rows', () async {
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    await store.emit(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 2},
    );
    // Freeze rows 1 and 2.
    await store.pendingOps();
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 3},
    );

    // Only seq 1 is acknowledged: seq 2 stays frozen, seq 3 is appending-only.
    await store.markPushed(1);
    time.advance(1);
    final afterPartial = await store.emit(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 4},
    );
    expect(afterPartial.seq, 4);

    // Acknowledging up to seq 3 clears the freeze; seq 4 can coalesce again.
    await store.markPushed(3);
    time.advance(1);
    final coalesced = await store.emit(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 5},
    );
    expect(coalesced.seq, 4);
    expect(await store.pendingCount(), 1);
  });

  test('clear coalescing respects the freeze', () async {
    final clear1 = await store.emitClear(_history);
    expect(clear1.seq, 1);
    await store.pendingOps();

    final clear2 = await store.emitClear(_history);
    expect(clear2.seq, 2);

    final ops = await store.pendingOps();
    expect(ops.map((op) => op.seq), [1, 2]);
    expect(ops[0].kind, SyncOpKind.clear);
    expect(ops[0].version, clear1.version);
    expect(ops[1].kind, SyncOpKind.clear);
    expect(ops[1].version.compareTo(clear1.version), greaterThan(0));
    // The persistent cutoff is still the max version of both clears.
    expect((await store.dumpClears()).single.cutoff, clear2.version);

    // Ack both rows: the freeze is cleared and clear coalescing resumes.
    await store.markPushed(2);
    time.advance(5);
    final clear3 = await store.emitClear(_history);
    expect(clear3.seq, 3);
    time.advance(5);
    final clear4 = await store.emitClear(_history);
    expect(clear4.seq, 3);
    expect(await store.pendingCount(), 1);
  });

  test('rejects invalid emit arguments and clear through emit', () async {
    await expectLater(
      store.emit(domain: _history, key: _historyKey1, kind: SyncOpKind.clear),
      throwsArgumentError,
    );
    await expectLater(
      store.emit(
        domain: 'bad domain!',
        key: _historyKey1,
        kind: SyncOpKind.upsert,
      ),
      throwsArgumentError,
    );
    await expectLater(
      store.emit(
        domain: _history,
        key: _historyKey1,
        field: 'bad field!',
        kind: SyncOpKind.upsert,
      ),
      throwsArgumentError,
    );
    await expectLater(store.emitClear('bad domain!'), throwsArgumentError);
    expect(await store.pendingCount(), 0);
    expect(
      () => SqliteSyncStore(
        dbPath: '${dir.path}/bad.db',
        deviceId: 'NOT-A-DEVICE',
        now: time.now,
      ),
      throwsArgumentError,
    );
  });

  // ---------------------------------------------------------------------------
  // Merge semantics
  // ---------------------------------------------------------------------------

  test('applyOps merges registers by LWW version', () async {
    final first = _remoteOp(seq: 1, ms: 1000, data: {'page': 1});
    var stats = await store.applyOps([first]);
    expect(stats.applied, 1);
    expect(stats.total, 1);

    var record = await store.recordOf(_history, _historyKey1, _progress);
    expect(record, isNotNull);
    expect(record!.data, {'page': 1});
    expect(record.version, first.version);

    final second = _remoteOp(seq: 2, ms: 1001, data: {'page': 2});
    stats = await store.applyOps([second]);
    expect(stats.applied, 1);

    final stale = _remoteOp(seq: 3, ms: 999, data: {'page': 3});
    stats = await store.applyOps([stale]);
    expect(stats.stale, 1);
    record = await store.recordOf(_history, _historyKey1, _progress);
    expect(record!.data, {'page': 2});

    stats = await store.applyOps([second]);
    expect(stats.duplicates, 1);
    expect(record.version, second.version);

    // Remote HLCs are observed: the next local emit is strictly greater.
    expect(await store.pendingCount(), 0);
    final local = await store.emit(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 0},
    );
    expect(local.version.hlc.compareTo(second.version.hlc), greaterThan(0));
  });

  test('same HLC uses seq as a tie-break', () async {
    final low = _remoteOp(seq: 5, ms: 2000, data: {'v': 5});
    final high = _remoteOp(seq: 9, ms: 2000, data: {'v': 9});

    var stats = await store.applyOps([low, high]);
    expect(stats.applied, 2);
    var record = await store.recordOf(_history, _historyKey1, _progress);
    expect(record!.data, {'v': 9});
    expect(record.version, high.version);

    final other = SqliteSyncStore(
      dbPath: '${dir.path}/tie.db',
      deviceId: _deviceA,
      now: time.now,
    );
    extraStores.add(other);
    await other.init();
    stats = await other.applyOps([high, low]);
    expect(stats.applied, 1);
    expect(stats.stale, 1);
    record = await other.recordOf(_history, _historyKey1, _progress);
    expect(record!.data, {'v': 9});
    expect(record.version, high.version);
  });

  test('set ops add/del/revive follow LWW element-set semantics', () async {
    final key = _historyKey1;
    final add1 = _remoteOp(
      seq: 1,
      ms: 1000,
      kind: SyncOpKind.add,
      domain: _readLater,
      field: '',
    );
    expect((await store.applyOps([add1])).applied, 1);
    var record = await store.recordOf(_readLater, key, '');
    expect(record, isNotNull);
    expect(record!.visible, isTrue);

    final del2 = _remoteOp(
      seq: 2,
      ms: 1001,
      kind: SyncOpKind.del,
      domain: _readLater,
      field: '',
    );
    expect((await store.applyOps([del2])).applied, 1);
    record = await store.recordOf(_readLater, key, '');
    expect(record!.visible, isFalse);
    expect(record.deletedVersion, del2.version);

    final add3 = _remoteOp(
      seq: 3,
      ms: 1002,
      kind: SyncOpKind.add,
      domain: _readLater,
      field: '',
    );
    expect((await store.applyOps([add3])).applied, 1);
    record = await store.recordOf(_readLater, key, '');
    expect(record!.visible, isTrue);

    // A delete older than the add does not hide the element.
    final oldAdd = _remoteOp(
      seq: 4,
      ms: 1005,
      kind: SyncOpKind.add,
      domain: _readLater,
      key: const ['other', '1'],
      field: '',
    );
    final oldDel = _remoteOp(
      seq: 5,
      ms: 900,
      kind: SyncOpKind.del,
      domain: _readLater,
      key: const ['other', '1'],
      field: '',
    );
    await store.applyOps([oldAdd]);
    expect((await store.applyOps([oldDel])).applied, 1);
    final otherKey = _key('other', '1');
    record = await store.recordOf(_readLater, otherKey, '');
    expect(record!.visible, isTrue);
    expect(record.deletedVersion, oldDel.version);

    // Re-applying the same delete is a duplicate.
    expect((await store.applyOps([oldDel])).duplicates, 1);
  });

  test('clear cutoffs drop older late ops and never regress', () async {
    await store.applyOps([
      _remoteOp(seq: 1, ms: 1000, data: {'page': 1}),
    ]);
    final clear = _remoteOp(seq: 2, ms: 2000, kind: SyncOpKind.clear);
    expect((await store.applyOps([clear])).applied, 1);

    final late = _remoteOp(
      seq: 3,
      ms: 1500,
      key: const ['b', '1'],
      data: {'page': 9},
    );
    final lateStats = await store.applyOps([late]);
    expect(lateStats.skippedByCutoff, 1);
    expect(lateStats.applied, 0);
    expect(await store.recordOf(_history, _key('b', '1'), _progress), isNull);

    final newer = _remoteOp(
      seq: 4,
      ms: 3000,
      key: const ['b', '1'],
      data: {'page': 4},
    );
    expect((await store.applyOps([newer])).applied, 1);
    expect((await store.recordOf(_history, _key('b', '1'), _progress))!.data, {
      'page': 4,
    });

    final olderClear = _remoteOp(seq: 5, ms: 1900, kind: SyncOpKind.clear);
    expect((await store.applyOps([olderClear])).stale, 1);
    final clearCutoff = (await store.dumpClears()).single;
    expect(clearCutoff.cutoff, clear.version);
    expect(clearCutoff.cutoff.compareTo(olderClear.version), greaterThan(0));

    // Records older than the cutoff are not part of the dumped state.
    final dumped = (await store.dumpRecords()).toList();
    expect(dumped.any((record) => record.key == _historyKey1), isFalse);
    expect(dumped.any((record) => record.key == _key('b', '1')), isTrue);
  });

  test('applyOps rolls the whole batch back on failure', () async {
    final good = _remoteOp(
      seq: 1,
      ms: 1000,
      key: const ['ok', '1'],
      data: {'page': 1},
    );
    final bad = _remoteOp(
      seq: 2,
      ms: 1001,
      key: const ['bad', '1'],
      // Not JSON encodable: forces a failure in the middle of the transaction.
      data: {'bad': Object()},
    );
    await expectLater(store.applyOps([good, bad]), throwsA(anything));
    expect(await store.recordOf(_history, _key('ok', '1'), _progress), isNull);
    expect(await store.recordOf(_history, _key('bad', '1'), _progress), isNull);
    expect(await store.applyOps([good]), isA<SyncApplyStats>());
    expect(await store.pendingCount(), 0);
  });

  test('applyOps aggregates stats over a mixed batch', () async {
    await store.applyOps([
      _remoteOp(seq: 1, ms: 1000, data: {'page': 1}),
    ]);
    await store.applyOps([_remoteOp(seq: 2, ms: 2000, kind: SyncOpKind.clear)]);

    final stats = await store.applyOps([
      _remoteOp(seq: 3, ms: 1500, data: {'page': 2}),
      _remoteOp(seq: 4, ms: 4000, data: {'page': 3}),
      _remoteOp(seq: 5, ms: 3000, data: {'page': 2}),
      _remoteOp(seq: 4, ms: 4000, data: {'page': 3}),
    ]);
    expect(stats.applied, 1);
    expect(stats.stale, 1);
    expect(stats.skippedByCutoff, 1);
    expect(stats.duplicates, 1);
    expect(stats.total, 4);
    expect(stats.changed, isTrue);

    // Applying the same batch again is fully idempotent.
    final repeated = await store.applyOps([
      _remoteOp(seq: 4, ms: 4000, data: {'page': 3}),
    ]);
    expect(repeated.duplicates, 1);
    expect(repeated.applied, 0);
    expect((await store.recordOf(_history, _historyKey1, _progress))!.data, {
      'page': 3,
    });
    expect(await store.applyOps(const []), isA<SyncApplyStats>());
  });

  // ---------------------------------------------------------------------------
  // Snapshot apply / dump
  // ---------------------------------------------------------------------------

  test(
    'applySnapshot merges enabled domains and takes max watermarks',
    () async {
      await store.setApplied(_deviceA, 5);
      final snapshotHlc = Hlc(ms: 5000, counter: 0, deviceId: _deviceB);
      final info = SnapshotInfo(
        deviceId: _deviceB,
        hlc: snapshotHlc,
        rangeLo: 1,
        rangeHi: 10,
        applied: {_deviceA: 3, _deviceB: 7},
        domains: {_history, _readLater},
      );
      final historyRecord = SnapshotRecord(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        version: Version(Hlc(ms: 4000, counter: 0, deviceId: _deviceB), 6),
        data: {'page': 9},
      );
      final disabledDomainRecord = SnapshotRecord(
        domain: _readLater,
        key: _historyKey2,
        field: '',
        version: Version(Hlc(ms: 4100, counter: 0, deviceId: _deviceB), 7),
        data: const {},
      );
      final tombstone = SnapshotRecord(
        domain: _history,
        key: _key('gone', '1'),
        field: _progress,
        version: Version(Hlc(ms: 3700, counter: 0, deviceId: _deviceB), 8),
        deletedVersion: Version(
          Hlc(ms: 3900, counter: 0, deviceId: _deviceB),
          9,
        ),
      );
      final snapshot = ParsedSnapshot(
        info: info,
        clears: {
          _history: Version(Hlc(ms: 3500, counter: 0, deviceId: _deviceB), 5),
        },
        records: [historyRecord, disabledDomainRecord, tombstone],
      );

      final stats = await store.applySnapshot(
        snapshot,
        enabledDomains: {_history},
      );
      expect(stats.applied, 3); // clear + two history records
      expect(await store.pendingCount(), 0);

      final record = await store.recordOf(_history, _historyKey1, _progress);
      expect(record, isNotNull);
      expect(record!.data, {'page': 9});
      expect(record.version, historyRecord.version);
      expect(await store.recordOf(_readLater, _historyKey2, ''), isNull);
      final tomb = await store.recordOf(_history, _key('gone', '1'), _progress);
      expect(tomb, isNotNull);
      expect(tomb!.visible, isFalse);
      expect(tomb.deletedVersion, tombstone.deletedVersion);
      expect((await store.dumpClears()).single.domain, _history);

      // Watermarks are max-merged, never regressed.
      expect(await store.getAppliedSeq(_deviceA), 5);
      expect(await store.getAppliedSeq(_deviceB), 7);

      // The snapshot meta HLC is observed by the local clock.
      final local = await store.emit(
        domain: _history,
        key: _historyKey2,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 0},
      );
      expect(local.version.hlc.compareTo(snapshotHlc), greaterThan(0));

      // Re-applying the snapshot is idempotent.
      final repeated = await store.applySnapshot(
        snapshot,
        enabledDomains: {_history},
      );
      expect(repeated.applied, 0);
    },
  );

  test('applySnapshot rolls the whole snapshot back on failure', () async {
    final info = SnapshotInfo(
      deviceId: _deviceB,
      hlc: Hlc(ms: 5000, counter: 0, deviceId: _deviceB),
      rangeLo: 1,
      rangeHi: 5,
      applied: {_deviceB: 5},
      domains: {_history},
    );
    final good = SnapshotRecord(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      version: Version(Hlc(ms: 4000, counter: 0, deviceId: _deviceB), 1),
      data: {'page': 1},
    );
    final bad = SnapshotRecord(
      domain: _history,
      key: _historyKey2,
      field: _progress,
      version: Version(Hlc(ms: 4100, counter: 0, deviceId: _deviceB), 2),
      data: {'bad': Object()},
    );
    final snapshot = ParsedSnapshot(
      info: info,
      clears: {
        _history: Version(Hlc(ms: 3000, counter: 0, deviceId: _deviceB), 3),
      },
      records: [good, bad],
    );
    await expectLater(
      store.applySnapshot(snapshot, enabledDomains: {_history}),
      throwsA(anything),
    );
    expect(await store.recordOf(_history, _historyKey1, _progress), isNull);
    expect((await store.dumpClears()).toList(), isEmpty);
    expect(await store.getApplied(), isEmpty);
  });

  test(
    'applySnapshot accepts wire-format set members without a payload',
    () async {
      final info = SnapshotInfo(
        deviceId: _deviceB,
        hlc: Hlc(ms: 6000, counter: 0, deviceId: _deviceB),
        rangeLo: 1,
        rangeHi: 1,
        applied: const {},
        domains: {_readLater},
      );
      // Protocol §6.2 describes set members with no payload; the receiver must
      // still end up with a visible element.
      final member = SnapshotRecord(
        domain: _readLater,
        key: _historyKey1,
        field: '',
        version: Version(Hlc(ms: 5000, counter: 0, deviceId: _deviceB), 1),
      );
      await store.applySnapshot(
        ParsedSnapshot(info: info, clears: const {}, records: [member]),
        enabledDomains: {_readLater},
      );
      final record = await store.recordOf(_readLater, _historyKey1, '');
      expect(record, isNotNull);
      expect(record!.visible, isTrue);
    },
  );

  test('applySnapshot keeps newer local data', () async {
    final local = await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 10},
    );
    final info = SnapshotInfo(
      deviceId: _deviceB,
      hlc: Hlc(ms: local.version.hlc.ms + 1000, counter: 0, deviceId: _deviceB),
      rangeLo: 1,
      rangeHi: 1,
      applied: const {},
      domains: {_history},
    );
    final staleRecord = SnapshotRecord(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      version: Version(
        Hlc(ms: local.version.hlc.ms - 500, counter: 0, deviceId: _deviceB),
        1,
      ),
      data: {'page': 1},
    );
    final stats = await store.applySnapshot(
      ParsedSnapshot(info: info, clears: const {}, records: [staleRecord]),
      enabledDomains: {_history},
    );
    expect(stats.applied, 0);
    expect(stats.stale, 1);
    expect((await store.recordOf(_history, _historyKey1, _progress))!.data, {
      'page': 10,
    });
  });

  test('snapshot generated from dumps bootstraps a second store', () async {
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 5},
    );
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: 'meta',
      kind: SyncOpKind.upsert,
      data: {'title': 'T'},
    );
    await store.emit(
      domain: _readLater,
      key: _historyKey2,
      kind: SyncOpKind.add,
    );
    await store.emit(
      domain: _readLater,
      key: _key('gone', '1'),
      kind: SyncOpKind.del,
    );
    await store.emitClear('setting');

    final domains = {_history, _readLater, 'setting'};
    final nextSeq = await store.getNextSeq();
    final info = SnapshotInfo(
      deviceId: _deviceA,
      hlc: await store.tickHlcForMeta(),
      rangeLo: 1,
      rangeHi: nextSeq,
      applied: {_deviceA: nextSeq},
      domains: domains,
    );
    final clears = {
      for (final clear in await store.dumpClears(domains: domains))
        clear.domain: clear.cutoff,
    };
    final records = [
      for (final record in await store.dumpRecords(domains: domains))
        SnapshotRecord(
          domain: record.domain,
          key: record.key,
          field: record.field,
          version: record.version,
          deletedVersion: record.deletedVersion,
          data: record.data,
        ),
    ];
    expect(records.length, 4);
    expect(clears.length, 1);

    final bytes = SnapshotCodec.encode(info, clears, records);
    final parsed = SnapshotCodec.decode(bytes, expectedDeviceId: _deviceA);

    final target = SqliteSyncStore(
      dbPath: '${dir.path}/target.db',
      deviceId: _deviceB,
      now: time.now,
    );
    extraStores.add(target);
    await target.init();
    final stats = await target.applySnapshot(parsed, enabledDomains: domains);
    expect(stats.applied, records.length + clears.length);
    expect((await target.recordOf(_history, _historyKey1, _progress))!.data, {
      'page': 5,
    });
    expect(
      (await target.recordOf(_readLater, _historyKey2, ''))!.visible,
      isTrue,
    );
    expect(
      (await target.recordOf(_readLater, _key('gone', '1'), ''))!.visible,
      isFalse,
    );
    expect(await target.getAppliedSeq(_deviceA), nextSeq);
    expect((await target.dumpRecords()).length, records.length);
  });

  test('dumpRecords includes tombstones and filters by domain', () async {
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: 'meta',
      kind: SyncOpKind.upsert,
      data: {'title': 'x'},
    );
    await store.emit(
      domain: _readLater,
      key: _historyKey2,
      kind: SyncOpKind.del,
    );
    await store.emitClear('setting');

    final all = (await store.dumpRecords()).toList();
    expect(all.length, 3);
    final tombstone = all.firstWhere((record) => record.domain == _readLater);
    expect(tombstone.deletedVersion, isNotNull);
    expect(tombstone.visible, isFalse);
    expect(tombstone.data, isNull);
    final live = all.firstWhere(
      (record) => record.domain == _history && record.field == _progress,
    );
    expect(live.visible, isTrue);
    expect(live.data, {'page': 1});
    final meta = all.firstWhere(
      (record) => record.domain == _history && record.field == 'meta',
    );
    expect(meta.visible, isTrue);

    final historyOnly = (await store.dumpRecords(domains: {_history})).toList();
    expect(historyOnly.map((record) => record.domain).toSet(), {_history});
    expect((await store.dumpClears(domains: {_readLater})).toList(), isEmpty);
    expect((await store.dumpClears()).single.domain, 'setting');
  });

  // ---------------------------------------------------------------------------
  // Applied watermarks / meta / misc
  // ---------------------------------------------------------------------------

  test('applied watermarks never regress', () async {
    expect(await store.getApplied(), isEmpty);
    expect(await store.getAppliedSeq(_deviceB), 0);
    await store.setApplied(_deviceB, 5);
    await store.setApplied(_deviceB, 3);
    expect(await store.getAppliedSeq(_deviceB), 5);
    expect(await store.getApplied(), {_deviceB: 5});
  });

  test(
    'tickHlcForMeta advances the persisted clock without emitting',
    () async {
      final before = store.clock.last;
      final first = await store.tickHlcForMeta();
      expect(first.compareTo(before), greaterThan(0));
      final second = await store.tickHlcForMeta();
      expect(second.compareTo(first), greaterThan(0));
      expect(await store.pendingCount(), 0);
      expect(await store.getNextSeq(), 0);

      final emitted = await store.emit(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 1},
      );
      expect(emitted.version.hlc.compareTo(second), greaterThan(0));

      await store.close();
      store = SqliteSyncStore(
        dbPath: '${dir.path}/sync.db',
        deviceId: _deviceA,
        now: time.now,
      );
      await store.init();
      expect(store.clock.last.compareTo(second), greaterThanOrEqualTo(0));
      expect(await store.getNextSeq(), 1);
    },
  );

  test('versionOf/recordOf reflect the latest merged version', () async {
    final key = _historyKey1;
    expect(await store.versionOf(_history, key, _progress), isNull);
    expect(await store.recordOf(_history, key, _progress), isNull);

    final emitted = await store.emit(
      domain: _history,
      key: key,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: {'page': 1},
    );
    expect(await store.versionOf(_history, key, _progress), emitted.version);

    time.advance(1);
    final remote = _remoteOp(
      seq: 1,
      ms: emitted.version.hlc.ms + 10000,
      data: {'page': 2},
    );
    await store.applyOps([remote]);
    expect(await store.versionOf(_history, key, _progress), remote.version);
    final record = await store.recordOf(_history, key, _progress);
    expect(record!.data, {'page': 2});
    expect(record.visible, isTrue);
  });

  test(
    'two store instances on the same file allocate unique HLCs and seqs',
    () async {
      await store.close();
      final first = SqliteSyncStore(
        dbPath: '${dir.path}/sync.db',
        deviceId: _deviceA,
        now: time.now,
      );
      final second = SqliteSyncStore(
        dbPath: '${dir.path}/sync.db',
        deviceId: _deviceA,
        now: time.now,
      );
      extraStores.addAll([first, second]);
      await first.init();
      await second.init();

      final op1 = await first.emit(
        domain: _history,
        key: _key('a', '1'),
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 1},
      );
      // `second` loaded its clock before op1 was written; it must still allocate
      // a strictly greater HLC (read-modify-write inside BEGIN IMMEDIATE).
      time.advance(3);
      final op2 = await second.emit(
        domain: _history,
        key: _key('b', '1'),
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 2},
      );
      final op3 = await first.emit(
        domain: _history,
        key: _key('c', '1'),
        field: _progress,
        kind: SyncOpKind.upsert,
        data: {'page': 3},
      );

      expect(op2.version.hlc.compareTo(op1.version.hlc), greaterThan(0));
      expect(op3.version.hlc.compareTo(op2.version.hlc), greaterThan(0));
      expect({op1.seq, op2.seq, op3.seq}, {1, 2, 3});

      final pendingFirst = (await first.pendingOps())
          .map((op) => op.seq)
          .toList();
      final pendingSecond = (await second.pendingOps())
          .map((op) => op.seq)
          .toList();
      expect(pendingFirst, [1, 2, 3]);
      expect(pendingSecond, [1, 2, 3]);
      expect((await first.dumpRecords()).length, 3);
      expect(
        await second.recordOf(_history, _key('a', '1'), _progress),
        isNotNull,
      );
      expect(await second.pendingCount(), 3);
    },
  );

  test('operations require an open store and reopen works', () async {
    await store.close();
    await expectLater(store.pendingCount(), throwsStateError);
    await expectLater(
      store.emit(
        domain: _history,
        key: _historyKey1,
        field: _progress,
        kind: SyncOpKind.upsert,
      ),
      throwsStateError,
    );
    await store.init();
    expect(await store.pendingCount(), 0);
  });

  test('logs recent LWW conflicts and can clear them', () async {
    await store.emit(
      domain: _history,
      key: _historyKey1,
      field: _progress,
      kind: SyncOpKind.upsert,
      data: <String, Object?>{'ep': 9},
    );
    final stats = await store.applyOps([
      _remoteOp(seq: 1, ms: 1762345677000, data: <String, Object?>{'ep': 1}),
    ]);
    expect(stats.stale, 1);
    final conflicts = await store.getRecentConflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single['domain'], _history);
    expect(conflicts.single['remoteHlc'], contains(_deviceB));
    await store.clearConflicts();
    expect(await store.getRecentConflicts(), isEmpty);
  });
}
