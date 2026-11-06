import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/sync/app/adapters/read_later_adapter.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';

const _readLaterSchema = '''
CREATE TABLE IF NOT EXISTS read_later (
  id TEXT NOT NULL,
  type INTEGER NOT NULL,
  title TEXT NOT NULL,
  subtitle TEXT,
  cover TEXT NOT NULL,
  source_key TEXT NOT NULL,
  added_time INTEGER NOT NULL,
  PRIMARY KEY (id, type)
);
''';

void main() {
  late Directory dir;
  late String readLaterPath;
  late SqliteSyncStore store;
  late List<String> warnings;
  late int reloads;
  late int nowMs;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);

  void tick() => nowMs += 1;

  ReadLaterAdapter newAdapter({bool withReload = true}) {
    return ReadLaterAdapter(
      dbPath: readLaterPath,
      reload: withReload
          ? () async {
              reloads++;
            }
          : null,
      onWarning: warnings.add,
    );
  }

  Database openBusinessDb() => sqlite3.open(readLaterPath);

  void createSchema() {
    final db = openBusinessDb();
    db.execute(_readLaterSchema);
    db.dispose();
  }

  void insertRow({
    required String id,
    int type = 1,
    String title = 'Title',
    String? subtitle,
    String cover = 'Cover',
    String sourceKey = 'source',
    int addedTime = 100,
  }) {
    final db = openBusinessDb();
    try {
      db.execute(
        'INSERT OR REPLACE INTO read_later '
        '(id, type, title, subtitle, cover, source_key, added_time) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, type, title, subtitle, cover, sourceKey, addedTime],
      );
    } finally {
      db.dispose();
    }
  }

  List<Map<String, Object?>> rows() {
    final db = openBusinessDb();
    try {
      return db
          .select('SELECT * FROM read_later ORDER BY id, type')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Future<void> emitAdd({
    required String id,
    int type = 1,
    Map<String, Object?>? data,
  }) async {
    tick();
    await store.emit(
      domain: SyncDomains.readLater,
      key: SyncKeys.readLaterKey(id, type.toString()),
      field: SyncFields.empty,
      kind: SyncOpKind.add,
      data: data,
    );
  }

  Future<void> emitDelete({required String id, int type = 1}) async {
    tick();
    await store.emit(
      domain: SyncDomains.readLater,
      key: SyncKeys.readLaterKey(id, type.toString()),
      field: SyncFields.empty,
      kind: SyncOpKind.del,
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('venera-read-later-adapter-');
    readLaterPath = '${dir.path}/read_later.db';
    warnings = <String>[];
    reloads = 0;
    nowMs = 1762345678000;
    store = SqliteSyncStore(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceA,
      now: now,
    );
    await store.init();
    createSchema();
  });

  tearDown(() async {
    await store.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  group('readLocalRecords', () {
    test('emits one add record per row', () async {
      insertRow(
        id: 'comic-a',
        type: 1,
        title: 'Comic A',
        subtitle: 'Sub A',
        cover: 'cover-a',
        sourceKey: 'source-a',
        addedTime: 111,
      );
      insertRow(
        id: 'comic-b',
        type: 42,
        title: 'Comic B',
        subtitle: null,
        cover: 'cover-b',
        sourceKey: 'source-b',
        addedTime: 222,
      );

      final records = await newAdapter().readLocalRecords();

      expect(records, hasLength(2));
      expect(
        records.every((record) => record.domain == SyncDomains.readLater),
        isTrue,
      );
      expect(records.every((record) => record.kind == SyncOpKind.add), isTrue);
      expect(
        records.every((record) => record.field == SyncFields.empty),
        isTrue,
      );

      final a = records.firstWhere(
        (record) => record.key == SyncKeys.readLaterKey('comic-a', '1'),
      );
      expect(a.data, {
        'title': 'Comic A',
        'subtitle': 'Sub A',
        'cover': 'cover-a',
        'source_key': 'source-a',
        'added_time': 111,
      });

      final b = records.firstWhere(
        (record) => record.key == SyncKeys.readLaterKey('comic-b', '42'),
      );
      expect(b.key.parts, ['comic-b', '42']);
      expect(b.data, {
        'title': 'Comic B',
        'subtitle': null,
        'cover': 'cover-b',
        'source_key': 'source-b',
        'added_time': 222,
      });
    });

    test('returns no records for an empty database', () async {
      expect(await newAdapter().readLocalRecords(), isEmpty);
    });

    test('tolerates a missing table', () async {
      final adapter = ReadLaterAdapter(
        dbPath: '${dir.path}/missing.db',
        onWarning: warnings.add,
      );
      expect(await adapter.readLocalRecords(), isEmpty);
      expect(warnings, isNotEmpty);
    });

    test('skips malformed rows instead of throwing', () async {
      insertRow(id: 'valid');
      final db = openBusinessDb();
      try {
        // A blob bypasses TEXT affinity, producing a non-string id.
        db.execute(
          "INSERT INTO read_later "
          "(id, type, title, cover, source_key, added_time) "
          "VALUES (x'00', 1, 'bad', 'cover', 'source', 1)",
        );
      } finally {
        db.dispose();
      }

      final records = await newAdapter().readLocalRecords();

      expect(records, hasLength(1));
      expect(records.single.key.parts.first, 'valid');
      expect(warnings, isNotEmpty);
    });
  });

  group('applyRemote', () {
    test('upserts visible records into the business table', () async {
      await emitAdd(
        id: 'comic-a',
        data: {
          'title': 'Remote A',
          'subtitle': 'Sub A',
          'cover': 'cover-a',
          'source_key': 'source-a',
          'added_time': 222,
        },
      );
      await emitAdd(
        id: 'comic-b',
        type: 7,
        data: {
          'title': 'Remote B',
          'subtitle': null,
          'cover': 'cover-b',
          'source_key': 'source-b',
          'added_time': 333,
        },
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(all, hasLength(2));
      expect(all[0]['id'], 'comic-a');
      expect(all[0]['type'], 1);
      expect(all[0]['title'], 'Remote A');
      expect(all[0]['subtitle'], 'Sub A');
      expect(all[0]['cover'], 'cover-a');
      expect(all[0]['source_key'], 'source-a');
      expect(all[0]['added_time'], 222);
      expect(all[1]['id'], 'comic-b');
      expect(all[1]['type'], 7);
      expect(all[1]['subtitle'], isNull);
      expect(reloads, 1);
    });

    test('deletes business rows without a visible record', () async {
      insertRow(id: 'keep');
      insertRow(id: 'drop');
      await emitAdd(
        id: 'keep',
        data: {'title': 'Keep', 'cover': 'cover', 'source_key': 'key'},
      );

      await newAdapter().applyRemote(store);

      expect(rows().map((row) => row['id']), ['keep']);
      expect(reloads, 1);
    });

    test('propagates remote tombstones as local deletes', () async {
      insertRow(id: 'alive');
      insertRow(id: 'gone');
      await emitAdd(
        id: 'alive',
        data: {'title': 'Alive', 'cover': 'cover', 'source_key': 'key'},
      );
      await emitAdd(
        id: 'gone',
        data: {'title': 'Gone', 'cover': 'cover', 'source_key': 'key'},
      );
      await emitDelete(id: 'gone');

      await newAdapter().applyRemote(store);

      expect(rows().map((row) => row['id']), ['alive']);
      expect(reloads, 1);
    });

    test('an empty store clears the business table', () async {
      insertRow(id: 'comic-a');
      insertRow(id: 'comic-b', type: 2);

      await newAdapter().applyRemote(store);

      expect(rows(), isEmpty);
      expect(reloads, 1);
    });

    test('combines a partial payload with the existing business row', () async {
      insertRow(
        id: 'partial',
        title: 'Existing',
        subtitle: 'Existing sub',
        cover: 'existing-cover',
        sourceKey: 'existing-source',
        addedTime: 100,
      );
      await emitAdd(id: 'partial', data: {'added_time': 999});

      await newAdapter().applyRemote(store);

      final row = rows().single;
      expect(row['added_time'], 999);
      expect(row['title'], 'Existing');
      expect(row['subtitle'], 'Existing sub');
      expect(row['cover'], 'existing-cover');
      expect(row['source_key'], 'existing-source');
    });

    test('tolerates malformed records and payloads', () async {
      insertRow(id: 'stale');
      await emitAdd(
        id: 'good',
        data: {
          'title': 'Good',
          'subtitle': null,
          'cover': 'cover',
          'source_key': 'source',
          'added_time': 5,
        },
      );
      await emitAdd(
        id: 'bad-payload',
        data: {'title': 123, 'cover': null, 'added_time': 'oops'},
      );
      // A key that cannot be mapped to a read_later row must be skipped.
      tick();
      await store.emit(
        domain: SyncDomains.readLater,
        key: SyncKey(const ['broken-key']),
        field: SyncFields.empty,
        kind: SyncOpKind.add,
        data: {'title': 'Broken'},
      );
      // Add without payload (older/v1-ish peers): defaults are used.
      await emitAdd(id: 'no-payload');

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(warnings, isNotEmpty);
      expect(all.map((row) => row['id']), [
        'bad-payload',
        'good',
        'no-payload',
      ]);
      expect(all[0]['title'], '123');
      expect(all[0]['cover'], '');
      expect(all[0]['added_time'], 0);
      expect(all[2]['title'], '');
      expect(all[2]['cover'], '');
      expect(all[2]['source_key'], '');
      expect(all[2]['added_time'], 0);
      expect(reloads, 1);
    });

    test('works without a reload callback', () async {
      await emitAdd(
        id: 'comic-a',
        data: {'title': 'A', 'cover': 'cover', 'source_key': 'key'},
      );

      await newAdapter(withReload: false).applyRemote(store);

      expect(rows(), hasLength(1));
      expect(reloads, 0);
    });

    test('is idempotent when applied repeatedly', () async {
      await emitAdd(
        id: 'comic-a',
        data: {'title': 'A', 'cover': 'cover', 'source_key': 'key'},
      );
      final adapter = newAdapter();
      await adapter.applyRemote(store);
      final first = rows();
      await adapter.applyRemote(store);
      expect(rows(), first);
      expect(reloads, 2);
      expect(warnings, isEmpty);
    });

    test('reload() invokes the injected callback', () async {
      final adapter = newAdapter();
      await adapter.reload();
      expect(reloads, 1);
      await newAdapter(withReload: false).reload();
      expect(reloads, 1);
    });

    test('tolerates a missing business table', () async {
      final adapter = ReadLaterAdapter(
        dbPath: '${dir.path}/missing.db',
        reload: () async {
          reloads++;
        },
        onWarning: warnings.add,
      );
      await adapter.applyRemote(store);
      expect(warnings, isNotEmpty);
      expect(reloads, 0);
    });
  });
}
