import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/sync/app/adapters/history_adapter.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';

const _historySchema = '''
CREATE TABLE IF NOT EXISTS history (
  id text,
  title text,
  subtitle text,
  cover text,
  time int,
  type int,
  ep int,
  page int,
  readEpisode text,
  max_page int,
  chapter_group int,
  primary key (id, type)
);
''';

void main() {
  late Directory dir;
  late String historyPath;
  late SqliteSyncStore store;
  late List<String> warnings;
  late int reloads;
  late int nowMs;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);

  void tick() => nowMs += 1;

  HistoryAdapter newAdapter({bool withReload = true, bool withWarning = true}) {
    return HistoryAdapter(
      dbPath: historyPath,
      reload: withReload
          ? () async {
              reloads++;
            }
          : null,
      onWarning: withWarning ? warnings.add : null,
    );
  }

  Database openBusinessDb() => sqlite3.open(historyPath);

  void createSchema() {
    final db = openBusinessDb();
    db.execute(_historySchema);
    db.dispose();
  }

  void insertRow({
    required String id,
    int type = 1,
    String? title = 'Title',
    String? subtitle,
    String? cover = 'Cover',
    int? time = 100,
    int? ep = 1,
    int? page = 2,
    String? readEpisode = '',
    int? maxPage,
    int? chapterGroup,
  }) {
    final db = openBusinessDb();
    try {
      db.execute(
        'INSERT OR REPLACE INTO history '
        '(id, title, subtitle, cover, time, type, ep, page, readEpisode, '
        'max_page, chapter_group) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          title,
          subtitle,
          cover,
          time,
          type,
          ep,
          page,
          readEpisode,
          maxPage,
          chapterGroup,
        ],
      );
    } finally {
      db.dispose();
    }
  }

  List<Map<String, Object?>> rows() {
    final db = openBusinessDb();
    try {
      return db
          .select('SELECT * FROM history ORDER BY id, type')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Future<void> emitHistory({
    required String id,
    int type = 1,
    Map<String, Object?>? progress,
    Map<String, Object?>? meta,
    bool deleted = false,
  }) async {
    final key = SyncKeys.historyKey(id, type.toString());
    if (progress != null || deleted) {
      tick();
      await store.emit(
        domain: SyncDomains.history,
        key: key,
        field: SyncFields.progress,
        kind: deleted ? SyncOpKind.del : SyncOpKind.upsert,
        data: deleted ? null : progress,
      );
    }
    if (meta != null || deleted) {
      tick();
      await store.emit(
        domain: SyncDomains.history,
        key: key,
        field: SyncFields.meta,
        kind: deleted ? SyncOpKind.del : SyncOpKind.upsert,
        data: deleted ? null : meta,
      );
    }
  }

  Map<String, Object?>? recordData(
    List<Map<String, Object?>> all,
    String id, {
    int type = 1,
  }) {
    for (final row in all) {
      if (row['id'] == id && row['type'] == type) return row;
    }
    return null;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('venera-history-adapter-');
    historyPath = '${dir.path}/history.db';
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
    test('emits one progress and one meta record per history row', () async {
      insertRow(
        id: 'comic-a',
        type: 1,
        title: 'Comic A',
        subtitle: 'Sub A',
        cover: 'https://cover/a.jpg',
        time: 111,
        ep: 3,
        page: 4,
        readEpisode: '1,2,3',
        maxPage: 20,
        chapterGroup: 2,
      );
      insertRow(
        id: 'comic-b',
        type: 42,
        title: 'Comic B',
        subtitle: null,
        cover: null,
        time: null,
        ep: null,
        page: null,
        readEpisode: null,
        maxPage: null,
        chapterGroup: null,
      );

      final records = await newAdapter().readLocalRecords();

      expect(records, hasLength(4));
      expect(
        records.every((record) => record.domain == SyncDomains.history),
        isTrue,
      );

      final keyA = SyncKeys.historyKey('comic-a', '1');
      final progressA = records.firstWhere(
        (record) => record.key == keyA && record.field == SyncFields.progress,
      );
      expect(progressA.kind, SyncOpKind.upsert);
      expect(progressA.data, {
        'ep': 3,
        'page': 4,
        'readEpisode': '1,2,3',
        'max_page': 20,
        'chapter_group': 2,
        'time': 111,
      });

      final metaA = records.firstWhere(
        (record) => record.key == keyA && record.field == SyncFields.meta,
      );
      expect(metaA.data, {
        'title': 'Comic A',
        'subtitle': 'Sub A',
        'cover': 'https://cover/a.jpg',
      });

      final keyB = SyncKeys.historyKey('comic-b', '42');
      expect(keyB.parts, ['comic-b', '42']);
      final progressB = records.firstWhere(
        (record) => record.key == keyB && record.field == SyncFields.progress,
      );
      expect(progressB.data, {
        'ep': 0,
        'page': 0,
        'readEpisode': '',
        'max_page': null,
        'chapter_group': null,
        'time': 0,
      });
      final metaB = records.firstWhere(
        (record) => record.key == keyB && record.field == SyncFields.meta,
      );
      expect(metaB.data, {'title': 'Comic B', 'subtitle': null, 'cover': ''});
    });

    test('returns no records for an empty database', () async {
      final records = await newAdapter().readLocalRecords();
      expect(records, isEmpty);
    });

    test('tolerates a missing table', () async {
      final missingPath = '${dir.path}/missing.db';
      final adapter = HistoryAdapter(
        dbPath: missingPath,
        onWarning: warnings.add,
      );
      expect(await adapter.readLocalRecords(), isEmpty);
      expect(warnings, isNotEmpty);
    });

    test('skips malformed rows instead of throwing', () async {
      insertRow(id: 'valid', type: 1);
      final db = openBusinessDb();
      try {
        // SQLite is dynamically typed: a blob bypasses TEXT affinity, so the
        // row really carries a non-string id.
        db.execute(
          "INSERT INTO history (id, type, title) VALUES (x'00', 1, 'bad')",
        );
      } finally {
        db.dispose();
      }

      final records = await newAdapter().readLocalRecords();

      expect(records, hasLength(2));
      expect(
        records.every((record) => record.key.parts.first == 'valid'),
        isTrue,
      );
      expect(warnings, isNotEmpty);
    });
  });

  group('applyRemote', () {
    test('upserts visible records into the business table', () async {
      await emitHistory(
        id: 'comic-a',
        progress: {
          'ep': 5,
          'page': 6,
          'readEpisode': '4,5',
          'max_page': 30,
          'chapter_group': 2,
          'time': 222,
        },
        meta: {'title': 'Remote A', 'subtitle': 'Sub', 'cover': 'cover-a'},
      );
      await emitHistory(
        id: 'comic-b',
        type: 7,
        progress: {'ep': 1, 'page': 2, 'time': 333},
        meta: {'title': 'Remote B', 'subtitle': null, 'cover': 'cover-b'},
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(all, hasLength(2));
      expect(all[0]['id'], 'comic-a');
      expect(all[0]['type'], 1);
      expect(all[0]['ep'], 5);
      expect(all[0]['page'], 6);
      expect(all[0]['readEpisode'], '4,5');
      expect(all[0]['max_page'], 30);
      expect(all[0]['chapter_group'], 2);
      expect(all[0]['time'], 222);
      expect(all[0]['title'], 'Remote A');
      expect(all[0]['subtitle'], 'Sub');
      expect(all[0]['cover'], 'cover-a');

      expect(all[1]['id'], 'comic-b');
      expect(all[1]['type'], 7);
      expect(all[1]['title'], 'Remote B');
      expect(all[1]['subtitle'], isNull);
      expect(reloads, 1);
    });

    test('deletes business rows without a visible record', () async {
      insertRow(id: 'keep');
      insertRow(id: 'drop');
      await emitHistory(
        id: 'keep',
        progress: {'ep': 2, 'page': 3, 'time': 10},
        meta: {'title': 'Keep', 'subtitle': null, 'cover': 'keep-cover'},
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(all.map((row) => row['id']), ['keep']);
      expect(reloads, 1);
    });

    test('propagates remote tombstones as local deletes', () async {
      insertRow(id: 'alive');
      insertRow(id: 'gone');
      await emitHistory(
        id: 'alive',
        progress: {'ep': 1, 'page': 1, 'time': 10},
        meta: {'title': 'Alive', 'subtitle': null, 'cover': ''},
      );
      await emitHistory(
        id: 'gone',
        progress: {'ep': 1, 'page': 1, 'time': 10},
        meta: {'title': 'Gone', 'subtitle': null, 'cover': ''},
      );
      // Tombstone both field groups at a strictly newer version.
      await emitHistory(id: 'gone', deleted: true);

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(all.map((row) => row['id']), ['alive']);
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
        time: 100,
        ep: 1,
        page: 2,
        readEpisode: '1',
        maxPage: 10,
        chapterGroup: 3,
      );
      // Only the progress register is visible: the meta columns must be kept.
      await emitHistory(
        id: 'partial',
        progress: {'ep': 9, 'page': 8, 'time': 200},
      );

      await newAdapter().applyRemote(store);

      final row = rows().single;
      expect(row['ep'], 9);
      expect(row['page'], 8);
      expect(row['time'], 200);
      expect(row['readEpisode'], '1');
      expect(row['max_page'], 10);
      expect(row['chapter_group'], 3);
      expect(row['title'], 'Existing');
      expect(row['subtitle'], 'Existing sub');
      expect(row['cover'], 'existing-cover');
    });

    test('tolerates malformed records and payloads', () async {
      insertRow(id: 'stale');
      await emitHistory(
        id: 'good',
        progress: {'ep': 3, 'page': 4, 'time': 5},
        meta: {'title': 'Good', 'subtitle': null, 'cover': ''},
      );
      // Wrong payload types: valid values still win, invalid ones fall back.
      await emitHistory(
        id: 'bad-progress',
        progress: {'ep': 'not-an-int', 'page': 9, 'time': 'oops'},
      );
      await emitHistory(id: 'bad-meta', meta: {'title': 123, 'cover': null});
      // A key that cannot be mapped to a history row must be skipped.
      tick();
      await store.emit(
        domain: SyncDomains.history,
        key: SyncKey(const ['broken-key']),
        field: SyncFields.progress,
        kind: SyncOpKind.upsert,
        data: {'ep': 1},
      );
      // Unknown field groups are ignored but keep the key present.
      tick();
      await store.emit(
        domain: SyncDomains.history,
        key: SyncKeys.historyKey('unknown-field', '1'),
        field: 'unknown',
        kind: SyncOpKind.upsert,
        data: {'value': 1},
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(warnings, isNotEmpty);
      expect(all.map((row) => row['id']), [
        'bad-meta',
        'bad-progress',
        'good',
        'unknown-field',
      ]);

      final good = recordData(all, 'good')!;
      expect(good['ep'], 3);
      expect(good['title'], 'Good');

      final badProgress = recordData(all, 'bad-progress')!;
      expect(badProgress['ep'], 0);
      expect(badProgress['page'], 9);
      expect(badProgress['time'], 0);

      final badMeta = recordData(all, 'bad-meta')!;
      expect(badMeta['title'], '123');
      expect(badMeta['cover'], '');

      expect(recordData(all, 'stale'), isNull);
      expect(recordData(all, 'broken-key'), isNull);
      expect(reloads, 1);
    });

    test('works without a reload callback', () async {
      await emitHistory(
        id: 'comic-a',
        progress: {'ep': 1, 'page': 1, 'time': 1},
        meta: {'title': 'A', 'subtitle': null, 'cover': ''},
      );

      await newAdapter(withReload: false).applyRemote(store);

      expect(rows(), hasLength(1));
      expect(reloads, 0);
    });

    test('is idempotent when applied repeatedly', () async {
      await emitHistory(
        id: 'comic-a',
        progress: {'ep': 1, 'page': 1, 'time': 1},
        meta: {'title': 'A', 'subtitle': null, 'cover': ''},
      );
      final adapter = newAdapter();
      await adapter.applyRemote(store);
      final first = rows();
      await adapter.applyRemote(store);
      final second = rows();
      expect(second, first);
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
      final adapter = HistoryAdapter(
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
