/// Acceptance tests for conflict resolution that the v1 whole-directory sync
/// could not handle.
///
/// v1 uploaded/downloaded one zipped snapshot of the whole data directory and
/// the last upload won. Two devices that edited *different* rows while offline
/// therefore overwrote each other: the later upload carried only its own local
/// state, so the other device's edits silently disappeared.
///
/// v2 merges per record with HLC versions. These tests assert the property v1
/// lacked — edits to different records and different set elements are all
/// **preserved**, not merely that the devices end up agreeing — plus the
/// delete-vs-edit ordering matrix:
///
///  * an edit older than a deletion cannot resurrect the record;
///  * an edit newer than a deletion intentionally brings it back.
///
/// They run in-process (SQLite + in-memory remote), no network/Flutter.
///
/// Note: same-key convergence is already covered by `engine_test.dart`
/// ("interleaved edits on both devices converge") and randomized agreement by
/// `integration_test.dart` ("random multi-device operations converge").
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/sync.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';
const _deviceB = 'bbbbbbbb-0000-0000-0000-00000000000b';

class _Device {
  _Device(this.store, this.engine);

  final SqliteSyncStore store;
  final SyncEngine engine;
}

void main() {
  late Directory tempDir;
  late FakeRemote remote;
  late int nowMs;
  final devices = <_Device>[];

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);
  void tick([int delta = 1]) => nowMs += delta;

  Future<_Device> open(String deviceId, String name) async {
    final store = await SqliteSyncStore.open(
      dbPath: '${tempDir.path}/$name.db',
      deviceId: deviceId,
      now: now,
    );
    final engine = SyncEngine(
      store: store,
      transport: FakeTransport(remote, label: name),
      enabledDomains: SyncDomains.enabledDomains(syncAuthEnabled: false),
      now: now,
    );
    await engine.init();
    final device = _Device(store, engine);
    devices.add(device);
    return device;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera_conflict_');
    remote = FakeRemote();
    nowMs = 1762345678000;
    devices.clear();
  });

  tearDown(() async {
    for (final device in devices) {
      await device.engine.close();
    }
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> writeProgress(_Device device, String comicId, int ep) async {
    tick();
    await device.store.emit(
      domain: SyncDomains.history,
      key: SyncKeys.historyKey(comicId, '1'),
      field: SyncFields.progress,
      kind: SyncOpKind.upsert,
      data: {'ep': ep, 'page': 0, 'time': nowMs},
    );
  }

  Future<void> deleteProgress(_Device device, String comicId) async {
    tick();
    await device.store.emit(
      domain: SyncDomains.history,
      key: SyncKeys.historyKey(comicId, '1'),
      field: SyncFields.progress,
      kind: SyncOpKind.del,
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

  Future<Map<String, Object?>?> progressOf(
    _Device device,
    String comicId,
  ) async {
    final record = await device.store.recordOf(
      SyncDomains.history,
      SyncKeys.historyKey(comicId, '1'),
      SyncFields.progress,
    );
    return record?.visible == true ? record!.data : null;
  }

  Future<bool> readLaterVisible(_Device device, String comicId) async {
    final record = await device.store.recordOf(
      SyncDomains.readLater,
      SyncKeys.readLaterKey(comicId, '1'),
      '',
    );
    return record?.visible == true;
  }

  test('offline edits to different records all survive', () async {
    final a = await open(_deviceA, 'a');
    final b = await open(_deviceB, 'b');

    // Shared baseline so both devices are in sync before going offline.
    await writeProgress(a, 'shared', 1);
    await a.engine.push();
    await b.engine.pull();

    // Offline: A edits one comic, B edits another. Neither has seen the other.
    await writeProgress(a, 'comic-a', 10);
    await writeProgress(b, 'comic-b', 20);

    // Both upload their own branch. In v1 the second whole-directory upload
    // would replace the first one and drop the other device's edit.
    await a.engine.push();
    await b.engine.push();
    await a.engine.pull();
    await b.engine.pull();

    for (final device in <_Device>[a, b]) {
      expect((await progressOf(device, 'shared'))!['ep'], 1);
      expect((await progressOf(device, 'comic-a'))!['ep'], 10);
      expect((await progressOf(device, 'comic-b'))!['ep'], 20);
    }
  });

  test('offline edits to different set elements all survive', () async {
    final a = await open(_deviceA, 'a');
    final b = await open(_deviceB, 'b');

    // "Read later" behaves like a favorites folder (LWW-Element-Set).
    await writeReadLater(a, 'seed', add: true);
    await a.engine.push();
    await b.engine.pull();

    await writeReadLater(a, 'from-a', add: true);
    await writeReadLater(b, 'from-b', add: true);

    await a.engine.push();
    await b.engine.push();
    await a.engine.pull();
    await b.engine.pull();

    for (final device in <_Device>[a, b]) {
      expect(await readLaterVisible(device, 'seed'), isTrue);
      expect(await readLaterVisible(device, 'from-a'), isTrue);
      expect(await readLaterVisible(device, 'from-b'), isTrue);
    }

    // Removing one element does not remove the other device's element.
    await writeReadLater(a, 'from-a', add: false);
    await a.engine.push();
    await b.engine.pull();
    expect(await readLaterVisible(b, 'from-a'), isFalse);
    expect(await readLaterVisible(b, 'from-b'), isTrue);
  });

  test('deletion and edit converge by version order', () async {
    final a = await open(_deviceA, 'a');
    final b = await open(_deviceB, 'b');

    await writeProgress(a, 'older-edit', 1);
    await writeProgress(a, 'newer-edit', 1);
    await a.engine.push();
    await b.engine.pull();

    // Record 1: B edits first, A deletes afterwards -> the tombstone is newer.
    await writeProgress(b, 'older-edit', 7);
    await deleteProgress(a, 'older-edit');

    // Record 2: A deletes first, B edits afterwards -> the edit is newer.
    await deleteProgress(a, 'newer-edit');
    await writeProgress(b, 'newer-edit', 8);

    await a.engine.push();
    await b.engine.push();
    await a.engine.pull();
    await b.engine.pull();

    for (final device in <_Device>[a, b]) {
      expect(
        await progressOf(device, 'older-edit'),
        isNull,
        reason: 'a deletion newer than the offline edit must win',
      );
      expect(
        (await progressOf(device, 'newer-edit'))!['ep'],
        8,
        reason: 'an edit newer than the deletion must bring the record back',
      );
    }
  });
}
