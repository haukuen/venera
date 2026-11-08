import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/sync.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';
const _deviceB = 'bbbbbbbb-0000-0000-0000-00000000000b';
const _deviceC = 'cccccccc-0000-0000-0000-00000000000c';

void main() {
  late Directory tempDir;
  late FakeRemote remote;
  late int nowMs;
  final devices = <String, _Device>{};

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);

  void tick([int delta = 1]) => nowMs += delta;

  Future<_Device> openDevice(
    String deviceId, {
    Set<String>? enabledDomains,
  }) async {
    final store = await SqliteSyncStore.open(
      dbPath: '${tempDir.path}/$deviceId.db',
      deviceId: deviceId,
      now: now,
    );
    final transport = FakeTransport(remote, label: deviceId);
    final engine = SyncEngine(
      store: store,
      transport: transport,
      enabledDomains:
          enabledDomains ?? SyncDomains.enabledDomains(syncAuthEnabled: false),
      now: now,
    );
    await engine.init();
    final device = _Device(store: store, transport: transport, engine: engine);
    devices[deviceId] = device;
    return device;
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('venera_sync_it_');
    remote = FakeRemote();
    nowMs = 1762345678000;
    devices.clear();
  });

  tearDown(() async {
    for (final device in devices.values) {
      await device.engine.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<Map<String, Object?>?> progress(_Device device, String comicId) async {
    final record = await device.store.recordOf(
      SyncDomains.history,
      SyncKeys.historyKey(comicId, '1'),
      SyncFields.progress,
    );
    return record?.data;
  }

  Future<void> writeProgress(
    _Device device,
    String comicId,
    int ep, {
    int page = 0,
  }) async {
    tick();
    await device.store.emit(
      domain: SyncDomains.history,
      key: SyncKeys.historyKey(comicId, '1'),
      field: SyncFields.progress,
      kind: SyncOpKind.upsert,
      data: {'ep': ep, 'page': page, 'time': nowMs},
    );
  }

  Future<void> writeSetting(_Device device, String key, Object? value) async {
    tick();
    await device.store.emit(
      domain: SyncDomains.setting,
      key: SyncKeys.settingKey(key),
      kind: SyncOpKind.upsert,
      data: {'value': value},
    );
  }

  Future<void> writeReadLater(
    _Device device,
    String comicId, {
    required bool add,
  }) async {
    tick();
    await device.store.emit(
      domain: SyncDomains.readLater,
      key: SyncKeys.readLaterKey(comicId, '1'),
      kind: add ? SyncOpKind.add : SyncOpKind.del,
    );
  }

  Future<Map<String, String>> visibleState(_Device device) async {
    final result = <String, String>{};
    for (final record in await device.store.dumpRecords()) {
      if (!record.visible) continue;
      result['${record.domain}|${record.key.encode()}|${record.field}'] =
          jsonEncode(record.data);
    }
    return result;
  }

  test('push then pull transfers a record', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);

    await writeProgress(a, 'comic-1', 3);
    final push = await a.engine.push();
    expect(push.success, isTrue);
    expect(push.opsPushed, 1);
    expect(push.lastPush, 1);

    final pull = await b.engine.pull();
    expect(pull.changed, isTrue);
    expect(pull.opsApplied, 1);
    expect(await progress(b, 'comic-1'), isNotNull);
    expect((await progress(b, 'comic-1'))!['ep'], 3);
  });

  test('interleaved edits converge to the latest version', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);

    await writeProgress(a, 'comic-1', 1);
    await a.engine.push();
    await b.engine.pull();

    await writeProgress(b, 'comic-1', 2);
    await b.engine.push();
    await a.engine.pull();

    await writeProgress(a, 'comic-1', 3);
    await a.engine.push();
    await b.engine.pull();
    await a.engine.pull();

    final aVersion = await a.store.versionOf(
      SyncDomains.history,
      SyncKeys.historyKey('comic-1', '1'),
      SyncFields.progress,
    );
    final bVersion = await b.store.versionOf(
      SyncDomains.history,
      SyncKeys.historyKey('comic-1', '1'),
      SyncFields.progress,
    );
    expect(aVersion, bVersion);
    expect((await progress(a, 'comic-1'))!['ep'], 3);
    expect((await progress(b, 'comic-1'))!['ep'], 3);
  });

  test('deletion and clear propagate', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);

    await writeProgress(a, 'comic-1', 1);
    await writeProgress(a, 'comic-2', 2);
    await a.engine.push();
    await b.engine.pull();
    expect((await visibleState(b)).length, 2);

    tick();
    await a.store.emit(
      domain: SyncDomains.history,
      key: SyncKeys.historyKey('comic-1', '1'),
      field: SyncFields.progress,
      kind: SyncOpKind.del,
    );
    await a.engine.push();
    await b.engine.pull();
    final deleted = await b.store.recordOf(
      SyncDomains.history,
      SyncKeys.historyKey('comic-1', '1'),
      SyncFields.progress,
    );
    expect(deleted, isNotNull);
    expect(deleted!.visible, isFalse);

    await a.store.emitClear(SyncDomains.history);
    await a.engine.push();
    await b.engine.pull();
    expect(
      await b.store
          .dumpRecords(domains: {SyncDomains.history})
          .then(
            (records) => records.where((record) => record.visible).toList(),
          ),
      isEmpty,
    );

    // A record written after the cutoff must survive.
    await writeProgress(a, 'comic-3', 4);
    await a.engine.push();
    await b.engine.pull();
    expect((await progress(b, 'comic-3'))!['ep'], 4);
  });

  test('snapshot + gc bootstraps a fresh device', () async {
    final a = await openDevice(_deviceA);
    await writeProgress(a, 'comic-1', 1);
    await writeProgress(a, 'comic-2', 2);
    await writeSetting(a, 'theme_mode', 'dark');
    await a.engine.push();

    final snapshot = await a.engine.snapshot();
    expect(snapshot.written, isTrue);
    expect(snapshot.records, greaterThanOrEqualTo(3));
    final gc = await a.engine.gc();
    expect(gc.deleted, isTrue);
    expect(gc.deletedUpTo, greaterThanOrEqualTo(1));

    final c = await openDevice(_deviceC);
    final pull = await c.engine.pull();
    expect(pull.snapshotsApplied, greaterThanOrEqualTo(1));
    expect((await progress(c, 'comic-1'))!['ep'], 1);
    expect((await progress(c, 'comic-2'))!['ep'], 2);
    final setting = await c.store.recordOf(
      SyncDomains.setting,
      SyncKeys.settingKey('theme_mode'),
      '',
    );
    expect(setting!.data!['value'], 'dark');
  });

  test('ambiguous write failure retries idempotently', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);
    await writeProgress(a, 'comic-1', 1);

    remote.failNextWrite(count: 1, afterCommit: true);
    final first = await a.engine.push();
    expect(first.error, isNotNull);
    expect(first.success, isFalse);
    expect(await a.store.pendingCount(), 1);

    remote.clearFaults();
    final second = await a.engine.push();
    expect(second.success, isTrue);
    expect(second.opsPushed, 1);
    expect(await a.store.pendingCount(), 0);

    await b.engine.pull();
    expect((await progress(b, 'comic-1'))!['ep'], 1);
    expect(remote.debugChanges(_deviceA).length, 1);
  });

  test('stale remote state does not hide uploaded changes', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);

    await writeProgress(a, 'comic-1', 1);
    await a.engine.push();
    remote.staleState(_deviceA);

    await writeProgress(a, 'comic-2', 2);
    final push = await a.engine.push();
    expect(push.success, isTrue);

    final pull = await b.engine.pull();
    expect(pull.changed, isTrue);
    expect((await progress(b, 'comic-1'))!['ep'], 1);
    expect((await progress(b, 'comic-2'))!['ep'], 2);
  });

  test('corrupt change file is repaired from snapshot', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);

    await writeProgress(a, 'comic-1', 1);
    await a.engine.push();
    await b.engine.pull();

    // The snapshot covers the delivered changes (and its automatic sweep
    // removes them), so the remaining corruption target is a change file
    // above the snapshot watermark.
    await writeProgress(a, 'comic-2', 2);
    await a.engine.push();
    await a.engine.snapshot();

    await writeProgress(a, 'comic-3', 3);
    await a.engine.push();

    final ranges = remote.debugChanges(_deviceA).keys.toList()..sort();
    expect(ranges, isNotEmpty);
    final tailRange = ranges.last.split('-');
    remote.corruptChange(
      _deviceA,
      int.parse(tailRange[0]),
      int.parse(tailRange[1]),
    );

    // The peer falls back to the snapshot for everything it covers; the
    // corrupt tail stays missing until the producer re-delivers it.
    final pull = await b.engine.pull();
    expect(pull.snapshotsApplied, greaterThanOrEqualTo(1));
    expect((await progress(b, 'comic-2'))!['ep'], 2);
    expect(await progress(b, 'comic-3'), isNull);
  });

  test('disabled domain ops advance watermark but are not applied', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(
      _deviceB,
      enabledDomains: SyncDomains.enabledDomains().difference({
        SyncDomains.readLater,
      }),
    );

    await writeProgress(a, 'comic-1', 1);
    await writeReadLater(a, 'comic-1', add: true);
    await a.engine.push();
    final pull = await b.engine.pull();
    expect(pull.changed, isTrue);
    expect(await b.store.getAppliedSeq(_deviceA), greaterThan(0));
    expect(
      await b.store.dumpRecords(domains: {SyncDomains.readLater}),
      isEmpty,
    );
    expect((await progress(b, 'comic-1'))!['ep'], 1);
  });

  test('pending batch is frozen against in-place coalescing', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);

    await writeProgress(a, 'comic-1', 1);
    final frozen = await a.store.pendingOps();
    expect(frozen.length, 1);

    await writeProgress(a, 'comic-1', 2);
    final pending = await a.store.pendingOps();
    expect(pending.length, 2);
    expect(pending.first.seq, frozen.first.seq);
    expect(pending.first.version, frozen.first.version);
    expect(pending.last.seq, greaterThan(frozen.first.seq));

    await a.engine.push();
    await b.engine.pull();
    expect((await progress(b, 'comic-1'))!['ep'], 2);
  });

  test('random multi-device operations converge', () async {
    final a = await openDevice(_deviceA);
    final b = await openDevice(_deviceB);
    final c = await openDevice(_deviceC);
    final all = [a, b, c];
    final random = Random(20261105);
    final comics = ['c1', 'c2', 'c3', 'c4'];

    Future<void> syncOne(_Device device) async {
      await device.engine.syncOnce();
    }

    for (var i = 0; i < 80; i++) {
      final device = all[random.nextInt(all.length)];
      switch (random.nextInt(5)) {
        case 0:
          await writeProgress(
            device,
            comics[random.nextInt(comics.length)],
            random.nextInt(10),
            page: random.nextInt(5),
          );
        case 1:
          await writeSetting(
            device,
            'setting-${random.nextInt(3)}',
            random.nextInt(100),
          );
        case 2:
          await writeReadLater(
            device,
            comics[random.nextInt(comics.length)],
            add: random.nextBool(),
          );
        case 3:
          await device.engine.push();
        case 4:
          await device.engine.pull();
      }
      if (random.nextInt(10) == 0) {
        await syncOne(all[random.nextInt(all.length)]);
      }
      if (random.nextInt(25) == 0) {
        await all[random.nextInt(all.length)].engine.snapshot();
      }
    }

    // Final settle: push everything, then pull twice on every device.
    for (var round = 0; round < 2; round++) {
      for (final device in all) {
        await device.engine.push();
      }
      for (final device in all) {
        await device.engine.pull();
      }
    }

    final expected = await visibleState(a);
    expect(await visibleState(b), expected);
    expect(await visibleState(c), expected);
    expect(expected, isNotEmpty);
  });
}

class _Device {
  _Device({required this.store, required this.transport, required this.engine});

  final SqliteSyncStore store;
  final FakeTransport transport;
  final SyncEngine engine;
}
