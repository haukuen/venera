/// Regression tests for the "local snapshot pointer vs. remote reality"
/// invariant (§7.2 step 6 / §7.4).
///
/// A device that was previously synced to another (or since recreated) remote
/// still carries a local `lastSnapshot` pointer. It must never advertise that
/// pointer to peers unless the file really exists on the current remote, and a
/// periodic snapshot check must re-upload a missing one. Otherwise peers see a
/// change-range gap starting at 0 that can never be repaired and stay stuck.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/sync.dart';

const String _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';
const String _deviceB = 'bbbbbbbb-0000-0000-0000-00000000000b';

void main() {
  late Directory tempDir;
  late int nowMs;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);
  void tick([int delta = 1]) => nowMs += delta;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera_snapshot_remote_');
    nowMs = 1762345678000;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<SyncOp> writeSetting(
    SqliteSyncStore store,
    String key,
    Object? value,
  ) async {
    tick();
    return store.emit(
      domain: SyncDomains.setting,
      key: SyncKeys.settingKey(key),
      kind: SyncOpKind.upsert,
      data: {'value': value},
    );
  }

  Future<SqliteSyncStore> openStore(String name) {
    return SqliteSyncStore.open(
      dbPath: '${tempDir.path}/$name.db',
      deviceId: name == 'a' ? _deviceA : _deviceB,
      now: now,
    );
  }

  test(
    'a snapshot pointer is re-uploaded after the remote was reset',
    () async {
      // Device A syncs to its original remote: 261 changes + snapshot.
      final oldRemote = FakeRemote();
      final storeA = await openStore('a');
      final engineA1 = SyncEngine(
        store: storeA,
        transport: FakeTransport(oldRemote, label: 'a-old'),
        now: now,
      );
      await engineA1.init();
      for (var i = 0; i < 261; i++) {
        await writeSetting(storeA, 'key-$i', i);
      }
      expect((await engineA1.push()).opsPushed, 261);
      final seeded = await engineA1.snapshot();
      expect(seeded.written, isTrue, reason: '${seeded.error}');
      await engineA1.close();

      // The user recreated/replaced the remote directory. Same local store,
      // empty remote: the old snapshot only exists locally.
      final newRemote = FakeRemote();
      final storeA2 = await openStore('a');
      final engineA2 = SyncEngine(
        store: storeA2,
        transport: FakeTransport(newRemote, label: 'a-new'),
        now: now,
      );
      await engineA2.init();
      for (var i = 261; i < 270; i++) {
        await writeSetting(storeA2, 'key-$i', i);
      }
      expect((await engineA2.push()).opsPushed, 9);

      // The state must not claim a snapshot the new remote does not have.
      final advertised = await engineA2.transport.readState(_deviceA);
      expect(advertised, isNotNull);
      expect(advertised!.lastChange, 270);
      expect(
        advertised.snapshot,
        isNull,
        reason: 'state advertised a snapshot missing from the new remote',
      );
      expect(newRemote.debugSnapshot(_deviceA), isNull);

      // A periodic snapshot check must notice and re-upload it.
      final rebuilt = await engineA2.maybeSnapshot();
      expect(rebuilt.written, isTrue, reason: '${rebuilt.error}');
      expect(newRemote.debugSnapshot(_deviceA), isNotNull);
      expect(await engineA2.transport.readSnapshotInfo(_deviceA), isNotNull);
      expect(
        (await engineA2.transport.readState(_deviceA))!.snapshot,
        isNotNull,
      );

      // A fresh peer can now bootstrap instead of failing with a gap.
      final storeB = await openStore('b');
      final engineB = SyncEngine(
        store: storeB,
        transport: FakeTransport(newRemote, label: 'b'),
        now: now,
      );
      await engineB.init();
      final pull = await engineB.pull();
      expect(
        pull.errors,
        isEmpty,
        reason: pull.errors.map((error) => error.message).join('\n'),
      );
      expect(pull.snapshotsApplied, greaterThanOrEqualTo(1));
      // A snapshot-only repair still changes local records: the app must
      // project them into its business databases (history, cookies, ...).
      expect(pull.changed, isTrue);
      expect(await storeB.getAppliedSeq(_deviceA), 270);
      final record = await storeB.recordOf(
        SyncDomains.setting,
        SyncKeys.settingKey('key-0'),
        SyncFields.empty,
      );
      expect(record?.data?['value'], 0);

      await engineA2.close();
      await engineB.close();
    },
  );

  test('gap errors name the missing snapshot', () async {
    final remote = FakeRemote();
    final storeA = await openStore('a');
    final engineA = SyncEngine(
      store: storeA,
      transport: FakeTransport(remote, label: 'a'),
      now: now,
    );
    await engineA.init();
    await writeSetting(storeA, 'only', true);
    expect((await engineA.push()).opsPushed, 1);
    // The change file vanishes; A never uploaded a snapshot.
    remote.missingCorruptChange(_deviceA, 1, 1);

    final storeB = await openStore('b');
    final engineB = SyncEngine(
      store: storeB,
      transport: FakeTransport(remote, label: 'b'),
      now: now,
    );
    await engineB.init();
    final pull = await engineB.pull();
    expect(pull.success, isFalse);
    expect(pull.errors, isNotEmpty);
    expect(
      pull.errors.first.message,
      contains('no usable snapshot'),
      reason: pull.errors.first.message,
    );

    await engineA.close();
    await engineB.close();
  });
}
