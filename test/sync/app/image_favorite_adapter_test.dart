import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/sync/app/adapters/image_favorite_adapter.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';

const _imageFavoritesSchema = '''
CREATE TABLE IF NOT EXISTS image_favorites (
  id TEXT,
  title TEXT NOT NULL,
  sub_title TEXT,
  author TEXT,
  tags TEXT,
  translated_tags TEXT,
  time int,
  max_page int,
  source_key TEXT NOT NULL,
  image_favorites_ep TEXT NOT NULL,
  other TEXT NOT NULL,
  PRIMARY KEY (id, source_key)
);
''';

const _epJson =
    '[{"eid":"ep-1","ep":1,"maxPage":20,"epName":"Chapter 1",'
    '"imageFavorites":[{"page":1,"imageKey":"key-1",'
    '"isAutoFavorite":true},{"page":2,"imageKey":"key-2"}]}]';

const _otherJson = '{"note":"hello","count":3,"flags":[true,null]}';

void main() {
  late Directory dir;
  late String historyPath;
  late SqliteSyncStore store;
  late List<String> warnings;
  late int reloads;
  late int nowMs;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);

  void tick() => nowMs += 1;

  ImageFavoriteAdapter newAdapter({bool withReload = true}) {
    return ImageFavoriteAdapter(
      dbPath: historyPath,
      reload: withReload
          ? () async {
              reloads++;
            }
          : null,
      onWarning: warnings.add,
    );
  }

  Database openBusinessDb() => sqlite3.open(historyPath);

  void createSchema() {
    final db = openBusinessDb();
    db.execute(_imageFavoritesSchema);
    db.dispose();
  }

  void insertRow({
    required String id,
    String sourceKey = 'source-a',
    String title = 'Title',
    String? subTitle,
    String? author = 'Author',
    String? tags = 'tag-1,tag-2',
    String? translatedTags = '标签1,标签2',
    int? time = 100,
    int? maxPage,
    String imageFavoritesEp = _epJson,
    String other = _otherJson,
  }) {
    final db = openBusinessDb();
    try {
      db.execute(
        'INSERT OR REPLACE INTO image_favorites '
        '(id, title, sub_title, author, tags, translated_tags, time, max_page, '
        'source_key, image_favorites_ep, other) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          title,
          subTitle,
          author,
          tags,
          translatedTags,
          time,
          maxPage,
          sourceKey,
          imageFavoritesEp,
          other,
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
          .select('SELECT * FROM image_favorites ORDER BY id, source_key')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Future<void> emitRecord({
    required String id,
    String sourceKey = 'source-a',
    Map<String, Object?>? data,
    bool deleted = false,
  }) async {
    tick();
    await store.emit(
      domain: SyncDomains.imageFavorite,
      key: SyncKey(<String>[id, sourceKey]),
      field: SyncFields.empty,
      kind: deleted ? SyncOpKind.del : SyncOpKind.upsert,
      data: deleted ? null : data,
    );
  }

  Map<String, Object?> dataFor({
    String id = 'comic-a',
    String sourceKey = 'source-a',
    String title = 'Remote',
    String? subTitle,
    String? author,
    String? tags,
    String? translatedTags,
    int? time,
    int? maxPage,
    String imageFavoritesEp = _epJson,
    String other = _otherJson,
  }) {
    return <String, Object?>{
      'id': id,
      'title': title,
      'sub_title': subTitle,
      'author': author,
      'tags': tags,
      'translated_tags': translatedTags,
      'time': time,
      'max_page': maxPage,
      'source_key': sourceKey,
      'image_favorites_ep': imageFavoritesEp,
      'other': other,
    };
  }

  Map<String, Object?>? recordFor(
    List<Map<String, Object?>> all,
    String id, {
    String sourceKey = 'source-a',
  }) {
    for (final row in all) {
      if (row['id'] == id && row['source_key'] == sourceKey) return row;
    }
    return null;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('venera-image-favorite-adapter-');
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
    test(
      'emits one row-level register per row preserving JSON strings',
      () async {
        insertRow(
          id: 'comic-a',
          title: 'Comic A',
          subTitle: 'Sub A',
          author: 'Author A',
          tags: 'tag-1,tag-2',
          translatedTags: '标签1,标签2',
          time: 111,
          maxPage: 20,
        );
        insertRow(
          id: '漫画/1',
          sourceKey: 'src@x',
          title: 'Unicode',
          subTitle: null,
          author: null,
          tags: null,
          translatedTags: null,
          time: null,
          maxPage: null,
          imageFavoritesEp: '[]',
          other: '{}',
        );

        final records = await newAdapter().readLocalRecords();

        expect(records, hasLength(2));
        expect(
          records.every((record) => record.domain == SyncDomains.imageFavorite),
          isTrue,
        );
        expect(
          records.every((record) => record.field == SyncFields.empty),
          isTrue,
        );
        expect(
          records.every((record) => record.kind == SyncOpKind.upsert),
          isTrue,
        );

        final keyA = SyncKey(const ['comic-a', 'source-a']);
        final recordA = records.firstWhere((record) => record.key == keyA);
        expect(recordA.data, {
          'id': 'comic-a',
          'title': 'Comic A',
          'sub_title': 'Sub A',
          'author': 'Author A',
          'tags': 'tag-1,tag-2',
          'translated_tags': '标签1,标签2',
          'time': 111,
          'max_page': 20,
          'source_key': 'source-a',
          // JSON strings must be preserved byte for byte.
          'image_favorites_ep': _epJson,
          'other': _otherJson,
        });

        final keyB = SyncKey(const ['漫画/1', 'src@x']);
        expect(keyB.parts, ['漫画/1', 'src@x']);
        final recordB = records.firstWhere((record) => record.key == keyB);
        expect(recordB.data, {
          'id': '漫画/1',
          'title': 'Unicode',
          'sub_title': null,
          'author': null,
          'tags': null,
          'translated_tags': null,
          'time': null,
          'max_page': null,
          'source_key': 'src@x',
          'image_favorites_ep': '[]',
          'other': '{}',
        });
      },
    );

    test('returns no records for an empty database', () async {
      expect(await newAdapter().readLocalRecords(), isEmpty);
    });

    test('tolerates a missing table', () async {
      final adapter = ImageFavoriteAdapter(
        dbPath: '${dir.path}/missing.db',
        onWarning: warnings.add,
      );
      expect(await adapter.readLocalRecords(), isEmpty);
      expect(warnings, isNotEmpty);
      // A missing table is an unreadable projection, not an emptied library:
      // the reconciler must keep the stored records of the domain.
      expect(
        await adapter.retainsDomainRecords(store, SyncDomains.imageFavorite),
        isTrue,
      );
    });

    test('skips malformed rows instead of throwing', () async {
      insertRow(id: 'valid', title: 'Valid');
      final db = openBusinessDb();
      try {
        // A blob bypasses TEXT affinity, producing a non-string id; the row
        // cannot be mapped to a sync key.
        db.execute(
          "INSERT INTO image_favorites "
          "(id, title, source_key, image_favorites_ep, other) "
          "VALUES (x'00', 'bad', 'source-a', '[]', '{}')",
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
    test('inserts visible records into an empty business table', () async {
      await emitRecord(
        id: 'comic-a',
        data: dataFor(
          title: 'Remote A',
          subTitle: 'Sub',
          author: 'Author',
          tags: 'a,b',
          translatedTags: '甲,乙',
          time: 222,
          maxPage: 20,
        ),
      );
      await emitRecord(
        id: 'comic-b',
        sourceKey: 'source-b',
        data: dataFor(
          id: 'comic-b',
          sourceKey: 'source-b',
          title: 'Remote B',
          imageFavoritesEp: '[]',
          other: '{}',
        ),
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(all, hasLength(2));

      final a = recordFor(all, 'comic-a')!;
      expect(a['title'], 'Remote A');
      expect(a['sub_title'], 'Sub');
      expect(a['author'], 'Author');
      expect(a['tags'], 'a,b');
      expect(a['translated_tags'], '甲,乙');
      expect(a['time'], 222);
      expect(a['max_page'], 20);
      expect(a['image_favorites_ep'], _epJson);
      expect(a['other'], _otherJson);

      final b = recordFor(all, 'comic-b', sourceKey: 'source-b')!;
      expect(b['title'], 'Remote B');
      expect(b['image_favorites_ep'], '[]');
      expect(b['other'], '{}');
      expect(reloads, 1);
    });

    test('updates an existing row from the remote register value', () async {
      insertRow(id: 'comic-a', title: 'Old', maxPage: 1);
      const newEpJson = '[{"eid":"ep-9","ep":9,"imageFavorites":[]}]';
      await emitRecord(
        id: 'comic-a',
        data: dataFor(
          title: 'New',
          maxPage: 99,
          imageFavoritesEp: newEpJson,
          other: '{}',
        ),
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(all, hasLength(1));
      expect(all.single['title'], 'New');
      expect(all.single['max_page'], 99);
      expect(all.single['image_favorites_ep'], newEpJson);
      expect(all.single['other'], '{}');
      expect(reloads, 1);
    });

    test('deletes business rows without a visible record', () async {
      insertRow(id: 'keep');
      insertRow(id: 'drop');
      await emitRecord(
        id: 'keep',
        data: dataFor(title: 'Keep'),
      );

      await newAdapter().applyRemote(store);

      expect(rows().map((row) => row['id']), ['keep']);
      expect(reloads, 1);
    });

    test('propagates remote tombstones as local deletes', () async {
      insertRow(id: 'alive');
      insertRow(id: 'gone');
      await emitRecord(
        id: 'alive',
        data: dataFor(title: 'Alive'),
      );
      await emitRecord(
        id: 'gone',
        data: dataFor(title: 'Gone'),
      );
      await emitRecord(id: 'gone', deleted: true);

      await newAdapter().applyRemote(store);

      expect(rows().map((row) => row['id']), ['alive']);
      expect(reloads, 1);
    });

    test('an empty store clears the business table', () async {
      insertRow(id: 'comic-a');
      insertRow(id: 'comic-b', sourceKey: 'source-b');

      await newAdapter().applyRemote(store);

      expect(rows(), isEmpty);
      expect(reloads, 1);
    });

    test('combines a partial payload with the existing row', () async {
      insertRow(
        id: 'partial',
        title: 'Existing',
        subTitle: 'Existing sub',
        author: 'Existing author',
        tags: 'existing-tags',
        translatedTags: 'existing-translated',
        time: 100,
        maxPage: 10,
      );
      await emitRecord(
        id: 'partial',
        data: {'title': 'New title', 'max_page': 99},
      );

      await newAdapter().applyRemote(store);

      final row = rows().single;
      expect(row['title'], 'New title');
      expect(row['max_page'], 99);
      expect(row['sub_title'], 'Existing sub');
      expect(row['author'], 'Existing author');
      expect(row['tags'], 'existing-tags');
      expect(row['translated_tags'], 'existing-translated');
      expect(row['time'], 100);
      expect(row['image_favorites_ep'], _epJson);
      expect(row['other'], _otherJson);
    });

    test('tolerates malformed records and payloads', () async {
      insertRow(id: 'stale');
      await emitRecord(
        id: 'good',
        data: dataFor(title: 'Good', maxPage: 5),
      );
      await emitRecord(
        id: 'bad',
        data: {
          'title': 123,
          'tags': <Object?>['not', 'a', 'string'],
          'image_favorites_ep': 42,
          'other': null,
          'max_page': 'oops',
          'time': true,
        },
      );
      // A key that cannot be mapped to a business row must be skipped.
      tick();
      await store.emit(
        domain: SyncDomains.imageFavorite,
        key: SyncKey(const ['broken-key']),
        field: SyncFields.empty,
        kind: SyncOpKind.upsert,
        data: {'title': 'Broken'},
      );
      // A named field group is not part of the row-level mapping.
      tick();
      await store.emit(
        domain: SyncDomains.imageFavorite,
        key: SyncKey(const ['wrong-field', 'source-a']),
        field: SyncFields.meta,
        kind: SyncOpKind.upsert,
        data: {'title': 'Wrong field'},
      );

      await newAdapter().applyRemote(store);

      final all = rows();
      expect(warnings, isNotEmpty);
      expect(all.map((row) => row['id']), ['bad', 'good']);

      final good = recordFor(all, 'good')!;
      expect(good['title'], 'Good');
      expect(good['max_page'], 5);

      final bad = recordFor(all, 'bad')!;
      expect(bad['title'], '123');
      expect(bad['tags'], isNull);
      expect(bad['image_favorites_ep'], '42');
      expect(bad['other'], '{}');
      expect(bad['max_page'], isNull);
      expect(bad['time'], isNull);

      expect(recordFor(all, 'stale'), isNull);
      expect(recordFor(all, 'broken-key'), isNull);
      expect(recordFor(all, 'wrong-field'), isNull);
      expect(reloads, 1);
    });

    test('works without a reload callback', () async {
      await emitRecord(id: 'comic-a', data: dataFor());

      await newAdapter(withReload: false).applyRemote(store);

      expect(rows(), hasLength(1));
      expect(reloads, 0);
    });

    test('is idempotent when applied repeatedly', () async {
      await emitRecord(
        id: 'comic-a',
        data: dataFor(title: 'A'),
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
      final adapter = ImageFavoriteAdapter(
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
