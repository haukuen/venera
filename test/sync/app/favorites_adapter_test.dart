import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/sync/app/adapters/favorites_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/app/folder_guard.dart';
import 'package:venera/sync/sync.dart';

const String _deviceId = 'aaaaaaaa-1111-2222-3333-444444444444';

const String _folderSchemaTemplate = '''
CREATE TABLE %s (
  id TEXT,
  name TEXT,
  author TEXT,
  type INTEGER,
  tags TEXT,
  cover_path TEXT,
  time TEXT,
  display_order INTEGER,
  translated_tags TEXT,
  PRIMARY KEY (id, type)
)''';

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

Map<String, Object?> _row({
  required String id,
  String name = 'Comic',
  String author = 'Author',
  int type = 1,
  String tags = '',
  String coverPath = '/covers/cover.jpg',
  String time = '2026-01-01 00:00:00',
  int displayOrder = 0,
  String? translatedTags,
}) {
  return <String, Object?>{
    'id': id,
    'name': name,
    'author': author,
    'type': type,
    'tags': tags,
    'cover_path': coverPath,
    'time': time,
    'display_order': displayOrder,
    'translated_tags': translatedTags,
  };
}

Map<String, Object?> _comicPayload(Map<String, Object?> row) {
  return <String, Object?>{
    'name': row['name'],
    'author': row['author'],
    'tags': row['tags'],
    'cover_path': row['cover_path'],
    'time': row['time'],
    'display_order': row['display_order'],
    'translated_tags': row['translated_tags'],
  };
}

void main() {
  late Directory dir;
  late String favoritesPath;
  late List<String> warnings;
  late int reloads;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('venera-favorites-adapter-');
    favoritesPath = '${dir.path}/local_favorite.db';
    warnings = <String>[];
    reloads = 0;
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  FavoritesAdapter newAdapter({
    bool withReload = true,
    bool withWarning = true,
    String? dbPath,
  }) {
    return FavoritesAdapter(
      dbPath: dbPath ?? favoritesPath,
      reload: withReload
          ? () async {
              reloads++;
            }
          : null,
      onWarning: withWarning ? warnings.add : null,
    );
  }

  Future<SqliteSyncStore> openStore() async {
    final store = await SqliteSyncStore.open(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceId,
    );
    addTearDown(store.close);
    return store;
  }

  void createFavoritesDb({
    required Map<String, List<Map<String, Object?>>> folders,
    Map<String, int> order = const <String, int>{},
    Map<String, List<String?>> links = const <String, List<String?>>{},
    String? dbPath,
  }) {
    final path = dbPath ?? favoritesPath;
    final db = sqlite3.open(path);
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS folder_order '
        '(folder_name TEXT PRIMARY KEY, order_value INTEGER)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS folder_sync '
        '(folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT)',
      );
      for (final entry in folders.entries) {
        db.execute(_folderSchemaTemplate.replaceFirst('%s', _quote(entry.key)));
        final insert =
            'INSERT INTO ${_quote(entry.key)} '
            '(${FavoritesAdapter.folderColumns.join(', ')}) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)';
        for (final row in entry.value) {
          db.execute(insert, <Object?>[
            row['id'],
            row['name'],
            row['author'],
            row['type'],
            row['tags'],
            row['cover_path'],
            row['time'],
            row['display_order'],
            row['translated_tags'],
          ]);
        }
      }
      for (final entry in order.entries) {
        db.execute(
          'INSERT INTO folder_order (folder_name, order_value) VALUES (?, ?)',
          <Object?>[entry.key, entry.value],
        );
      }
      for (final entry in links.entries) {
        db.execute(
          'INSERT INTO folder_sync '
          '(folder_name, source_key, source_folder) VALUES (?, ?, ?)',
          <Object?>[entry.key, entry.value[0], entry.value[1]],
        );
      }
    } finally {
      db.dispose();
    }
  }

  Set<String> tableNames() {
    final db = sqlite3.open(favoritesPath);
    try {
      return db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toSet();
    } finally {
      db.dispose();
    }
  }

  List<Map<String, Object?>> rows(String folder) {
    final db = sqlite3.open(favoritesPath);
    try {
      return db
          .select('SELECT * FROM ${_quote(folder)} ORDER BY id, type')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Map<String, int> orderRows() {
    final db = sqlite3.open(favoritesPath);
    try {
      final order = <String, int>{};
      for (final row in db.select('SELECT * FROM folder_order')) {
        order[row['folder_name'] as String] = row['order_value'] as int;
      }
      return order;
    } finally {
      db.dispose();
    }
  }

  Map<String, List<String?>> linkRows() {
    final db = sqlite3.open(favoritesPath);
    try {
      final links = <String, List<String?>>{};
      for (final row in db.select('SELECT * FROM folder_sync')) {
        links[row['folder_name'] as String] = <String?>[
          row['source_key'] as String?,
          row['source_folder'] as String?,
        ];
      }
      return links;
    } finally {
      db.dispose();
    }
  }

  Map<String, Object?>? rowById(List<Map<String, Object?>> all, String id) {
    for (final row in all) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  List<AdapterRecord> withDomain(List<AdapterRecord> records, String domain) =>
      records.where((record) => record.domain == domain).toList();

  group('readLocalRecords', () {
    test(
      'projects folders, members, order and links from local_favorite.db',
      () async {
        createFavoritesDb(
          folders: <String, List<Map<String, Object?>>>{
            '默认': <Map<String, Object?>>[
              _row(
                id: '1001',
                name: 'Comic One',
                tags: 'tag1,tag2',
                displayOrder: 0,
                translatedTags: '标签1',
              ),
              _row(id: '1002', name: 'Comic Two', type: 2, displayOrder: 1),
            ],
            'Reading List': <Map<String, Object?>>[
              _row(id: '2001', name: 'Read One'),
            ],
          },
          order: <String, int>{'Reading List': 0, '默认': 1},
          links: <String, List<String?>>{
            '默认': <String?>['ehentai', 'network-folder-1'],
          },
        );

        final adapter = newAdapter();
        final records = await adapter.readLocalRecords();

        expect(
          records.every((record) => adapter.domains.contains(record.domain)),
          isTrue,
          reason: 'adapter must only project its own domains',
        );

        final folders = withDomain(records, SyncDomains.favoriteFolder);
        expect(folders, hasLength(2));
        expect(
          folders.map((record) => record.key.parts.single).toSet(),
          <String>{'默认', 'Reading List'},
        );
        for (final record in folders) {
          expect(record.kind, SyncOpKind.add);
          expect(record.data, <String, Object?>{
            'name': record.key.parts.single,
          });
        }

        final comics = withDomain(records, SyncDomains.favoriteComic);
        expect(comics, hasLength(3));
        expect(comics.every((record) => record.kind == SyncOpKind.add), isTrue);
        final comic1001 = comics.singleWhere(
          (record) =>
              record.key.parts[0] == '默认' && record.key.parts[1] == '1001',
        );
        expect(comic1001.key.parts, <String>['默认', '1001', '1']);
        final data1001 = comic1001.data!;
        expect(data1001['name'], 'Comic One');
        expect(data1001['author'], 'Author');
        expect(data1001['tags'], 'tag1,tag2');
        expect(data1001['cover_path'], '/covers/cover.jpg');
        expect(data1001['time'], '2026-01-01 00:00:00');
        expect(data1001['display_order'], 0);
        expect(data1001['translated_tags'], '标签1');

        final comic1002 = comics.singleWhere(
          (record) => record.key.parts[1] == '1002',
        );
        expect(comic1002.key.parts, <String>['默认', '1002', '2']);

        final links = withDomain(records, SyncDomains.favoriteLink);
        expect(links, hasLength(1));
        expect(links.single.kind, SyncOpKind.upsert);
        expect(links.single.key.parts, <String>['默认']);
        expect(links.single.data, <String, Object?>{
          'source_key': 'ehentai',
          'source_folder': 'network-folder-1',
        });

        final orders = withDomain(records, SyncDomains.favoriteOrder);
        expect(orders, hasLength(1));
        expect(orders.single.kind, SyncOpKind.upsert);
        expect(orders.single.key, SyncKey(const <String>['order']));
        expect(orders.single.data!['folders'], <String>['Reading List', '默认']);

        expect(warnings, isEmpty);
      },
    );

    test(
      'projects an empty order register when the database is missing',
      () async {
        final adapter = newAdapter();
        final records = await adapter.readLocalRecords();

        expect(records, hasLength(1));
        expect(records.single.domain, SyncDomains.favoriteOrder);
        expect(records.single.kind, SyncOpKind.upsert);
        expect(records.single.data!['folders'], isEmpty);
        // Reading must not create the business database as a side effect.
        expect(File(favoritesPath).existsSync(), isFalse);
      },
    );

    test('tolerates a database without favorite folder tables', () async {
      createFavoritesDb(folders: const <String, List<Map<String, Object?>>>{});
      final records = await newAdapter().readLocalRecords();

      expect(records, hasLength(1));
      expect(records.single.domain, SyncDomains.favoriteOrder);
      expect(records.single.data!['folders'], isEmpty);
    });
  });

  group('applyRemote', () {
    test('rebuilds folder tables, members, order and links', () async {
      createFavoritesDb(
        folders: <String, List<Map<String, Object?>>>{
          'A': <Map<String, Object?>>[
            _row(id: '1', name: 'old one'),
            _row(id: '2', name: 'removed remotely', displayOrder: 1),
          ],
          'B': <Map<String, Object?>>[_row(id: '5', name: 'folder B')],
        },
        order: <String, int>{'A': 0, 'B': 1},
        links: <String, List<String?>>{
          'A': <String?>['srcA', 'nfA'],
          'B': <String?>['srcB', 'nfB'],
        },
      );
      final store = await openStore();

      await store.emit(
        domain: SyncDomains.favoriteFolder,
        key: SyncKeys.favoriteFolderKey('A'),
        kind: SyncOpKind.add,
        data: <String, Object?>{'name': 'A'},
      );
      await store.emit(
        domain: SyncDomains.favoriteFolder,
        key: SyncKeys.favoriteFolderKey('C'),
        kind: SyncOpKind.add,
        data: <String, Object?>{'name': 'C'},
      );
      await store.emit(
        domain: SyncDomains.favoriteComic,
        key: SyncKeys.favoriteComicKey('A', '1', '1'),
        kind: SyncOpKind.add,
        data: <String, Object?>{
          'name': 'new one',
          'author': 'new author',
          'tags': 't1,t2',
          'cover_path': '/covers/new.jpg',
          'time': '2026-02-01 00:00:00',
          'display_order': 7,
          'translated_tags': '新',
        },
      );
      await store.emit(
        domain: SyncDomains.favoriteComic,
        key: SyncKeys.favoriteComicKey('A', '3', '1'),
        kind: SyncOpKind.add,
        data: _comicPayload(_row(id: '3', name: 'new member', displayOrder: 8)),
      );
      await store.emit(
        domain: SyncDomains.favoriteComic,
        key: SyncKeys.favoriteComicKey('C', '9', '2'),
        kind: SyncOpKind.add,
        data: _comicPayload(
          _row(id: '9', name: 'C member', type: 2, displayOrder: 0),
        ),
      );
      // Remote deletion of A/2: a delete tombstone makes the member invisible.
      await store.emit(
        domain: SyncDomains.favoriteComic,
        key: SyncKeys.favoriteComicKey('A', '2', '1'),
        kind: SyncOpKind.del,
      );
      await store.emit(
        domain: SyncDomains.favoriteOrder,
        key: FavoritesAdapter.orderKey,
        kind: SyncOpKind.upsert,
        data: <String, Object?>{
          'folders': <String>['C', 'A'],
        },
      );
      await store.emit(
        domain: SyncDomains.favoriteLink,
        key: SyncKeys.favoriteLinkKey('A'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'source_key': 'srcA2', 'source_folder': 'nfA2'},
      );
      await store.emit(
        domain: SyncDomains.favoriteLink,
        key: SyncKeys.favoriteLinkKey('C'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'source_key': 'srcC', 'source_folder': 'nfC'},
      );

      final adapter = newAdapter();
      await adapter.applyRemote(store);

      expect(reloads, 1);
      expect(warnings, isEmpty);

      final tables = tableNames();
      expect(
        tables,
        containsAll(<String>['A', 'C', 'folder_order', 'folder_sync']),
      );
      expect(tables, isNot(contains('B')));

      final rowsA = rows('A');
      expect(rowsA.map((row) => row['id']), <Object?>['1', '3']);
      final updated = rowById(rowsA, '1')!;
      expect(updated['name'], 'new one');
      expect(updated['author'], 'new author');
      expect(updated['tags'], 't1,t2');
      expect(updated['cover_path'], '/covers/new.jpg');
      expect(updated['time'], '2026-02-01 00:00:00');
      expect(updated['display_order'], 7);
      expect(updated['translated_tags'], '新');
      expect(rowById(rowsA, '2'), isNull);

      final newMember = rowById(rowsA, '3')!;
      expect(newMember['name'], 'new member');
      expect(newMember['type'], 1);

      final rowsC = rows('C');
      expect(rowsC, hasLength(1));
      expect(rowsC.single['id'], '9');
      expect(rowsC.single['type'], 2);
      expect(rowsC.single['name'], 'C member');

      expect(orderRows(), <String, int>{'C': 0, 'A': 1});
      expect(linkRows(), <String, List<String?>>{
        'A': <String?>['srcA2', 'nfA2'],
        'C': <String?>['srcC', 'nfC'],
      });

      // A second projection is idempotent (data unchanged, reload still
      // invoked because the adapter reloads after every apply).
      await adapter.applyRemote(store);
      expect(reloads, 2);
      expect(rows('A'), rowsA);
      expect(tableNames(), tables);
    });

    test('projects the applied state back through readLocalRecords', () async {
      createFavoritesDb(
        folders: <String, List<Map<String, Object?>>>{
          'A': <Map<String, Object?>>[_row(id: '1')],
        },
      );
      final store = await openStore();
      await store.emit(
        domain: SyncDomains.favoriteFolder,
        key: SyncKeys.favoriteFolderKey('A'),
        kind: SyncOpKind.add,
        data: <String, Object?>{'name': 'A'},
      );
      await store.emit(
        domain: SyncDomains.favoriteFolder,
        key: SyncKeys.favoriteFolderKey('Z'),
        kind: SyncOpKind.add,
        data: <String, Object?>{'name': 'Z'},
      );
      await store.emit(
        domain: SyncDomains.favoriteComic,
        key: SyncKeys.favoriteComicKey('Z', '42', '3'),
        kind: SyncOpKind.add,
        data: _comicPayload(_row(id: '42', name: 'Zed', type: 3)),
      );
      await store.emit(
        domain: SyncDomains.favoriteOrder,
        key: FavoritesAdapter.orderKey,
        kind: SyncOpKind.upsert,
        data: <String, Object?>{
          'folders': <String>['Z', 'A'],
        },
      );

      final adapter = newAdapter();
      await adapter.applyRemote(store);
      final records = await adapter.readLocalRecords();

      final folderNames = withDomain(
        records,
        SyncDomains.favoriteFolder,
      ).map((record) => record.key.parts.single).toSet();
      expect(folderNames, <String>{'A', 'Z'});
      final order = withDomain(records, SyncDomains.favoriteOrder).single;
      expect(order.data!['folders'], <String>['Z', 'A']);
      final comics = withDomain(records, SyncDomains.favoriteComic);
      // A/1 had no favoriteComic record in the store, so the business row was
      // removed (the merged store is authoritative after seeding); Z's member
      // is projected.
      expect(comics, hasLength(1));
      expect(comics.single.key.parts, <String>['Z', '42', '3']);
      expect(rows('A'), isEmpty);
    });

    test(
      'skips invalid remote folder names and survives SQL injection',
      () async {
        createFavoritesDb(
          folders: <String, List<Map<String, Object?>>>{
            'A': <Map<String, Object?>>[_row(id: '1', name: 'keep me')],
          },
          order: <String, int>{'A': 0},
          links: <String, List<String?>>{
            'A': <String?>['srcA', 'nfA'],
          },
        );
        final store = await openStore();

        const injection = 'x"; DROP TABLE "A"; --';
        const injection2 = 'y; DROP TABLE A; --';
        await store.emit(
          domain: SyncDomains.favoriteFolder,
          key: SyncKeys.favoriteFolderKey('A'),
          kind: SyncOpKind.add,
          data: <String, Object?>{'name': 'A'},
        );
        for (final name in <String>[
          injection,
          injection2,
          'bad/name',
          ' \\x ',
        ]) {
          await store.emit(
            domain: SyncDomains.favoriteFolder,
            key: SyncKeys.favoriteFolderKey(name),
            kind: SyncOpKind.add,
            data: <String, Object?>{'name': name},
          );
        }
        await store.emit(
          domain: SyncDomains.favoriteComic,
          key: SyncKeys.favoriteComicKey('A', '1', '1'),
          kind: SyncOpKind.add,
          data: _comicPayload(_row(id: '1', name: 'keep me')),
        );
        await store.emit(
          domain: SyncDomains.favoriteComic,
          key: SyncKeys.favoriteComicKey(injection, '666', '1'),
          kind: SyncOpKind.add,
          data: <String, Object?>{'name': 'injected'},
        );
        await store.emit(
          domain: SyncDomains.favoriteLink,
          key: SyncKeys.favoriteLinkKey('A'),
          kind: SyncOpKind.upsert,
          data: <String, Object?>{'source_key': 'srcA', 'source_folder': 'nfA'},
        );
        await store.emit(
          domain: SyncDomains.favoriteLink,
          key: SyncKeys.favoriteLinkKey('bad/name'),
          kind: SyncOpKind.upsert,
          data: <String, Object?>{
            'source_key': 'evil',
            'source_folder': 'evil',
          },
        );
        await store.emit(
          domain: SyncDomains.favoriteOrder,
          key: FavoritesAdapter.orderKey,
          kind: SyncOpKind.upsert,
          data: <String, Object?>{
            'folders': <String>['A', injection, 'bad/name'],
          },
        );

        final adapter = newAdapter();
        await adapter.applyRemote(store);

        expect(reloads, 1);
        expect(warnings, isNotEmpty);
        expect(
          warnings.any(
            (message) => message.contains('invalid favorite folder'),
          ),
          isTrue,
        );
        expect(
          warnings.any((message) => message.contains('DROP TABLE')),
          isTrue,
          reason: 'the injection attempt must be reported, not executed',
        );

        // The real folder table is intact and untouched.
        expect(tableNames(), <String>{'A', 'folder_order', 'folder_sync'});
        final rowsA = rows('A');
        expect(rowsA, hasLength(1));
        expect(rowsA.single['name'], 'keep me');

        // Invalid names never reach folder_order / folder_sync.
        expect(orderRows(), <String, int>{'A': 0});
        expect(linkRows(), <String, List<String?>>{
          'A': <String?>['srcA', 'nfA'],
        });
      },
    );

    test(
      'keeps local order and links when the store has no such records',
      () async {
        final rowA = _row(id: '1');
        final rowB = _row(id: '2', name: 'B comic');
        createFavoritesDb(
          folders: <String, List<Map<String, Object?>>>{
            'A': <Map<String, Object?>>[rowA],
            'B': <Map<String, Object?>>[rowB],
          },
          order: <String, int>{'A': 0, 'B': 1},
          links: <String, List<String?>>{
            'A': <String?>['srcA', 'nfA'],
            'B': <String?>['srcB', 'nfB'],
          },
        );
        final store = await openStore();
        for (final folder in <String>['A', 'B']) {
          await store.emit(
            domain: SyncDomains.favoriteFolder,
            key: SyncKeys.favoriteFolderKey(folder),
            kind: SyncOpKind.add,
            data: <String, Object?>{'name': folder},
          );
        }
        await store.emit(
          domain: SyncDomains.favoriteComic,
          key: SyncKeys.favoriteComicKey('A', '1', '1'),
          kind: SyncOpKind.add,
          data: _comicPayload(rowA),
        );
        await store.emit(
          domain: SyncDomains.favoriteComic,
          key: SyncKeys.favoriteComicKey('B', '2', '1'),
          kind: SyncOpKind.add,
          data: _comicPayload(rowB),
        );

        await newAdapter().applyRemote(store);

        // No favoriteOrder / favoriteLink records were ever seeded: the adapter
        // must not wipe local rows that the store simply has not seen yet.
        expect(orderRows(), <String, int>{'A': 0, 'B': 1});
        expect(linkRows(), <String, List<String?>>{
          'A': <String?>['srcA', 'nfA'],
          'B': <String?>['srcB', 'nfB'],
        });
        expect(tableNames(), <String>{'A', 'B', 'folder_order', 'folder_sync'});
        expect(warnings, isEmpty);
        expect(reloads, 1);
      },
    );

    test(
      'creates the business database and parent directory when missing',
      () async {
        final freshPath = '${dir.path}/fresh/later/local_favorite.db';
        final store = await openStore();
        await store.emit(
          domain: SyncDomains.favoriteFolder,
          key: SyncKeys.favoriteFolderKey('远程'),
          kind: SyncOpKind.add,
          data: <String, Object?>{'name': '远程'},
        );
        await store.emit(
          domain: SyncDomains.favoriteComic,
          key: SyncKeys.favoriteComicKey('远程', '77', '1'),
          kind: SyncOpKind.add,
          data: _comicPayload(_row(id: '77', name: 'Remote Comic')),
        );

        final adapter = newAdapter(dbPath: freshPath);
        await adapter.applyRemote(store);

        expect(File(freshPath).existsSync(), isTrue);
        expect(reloads, 1);
        final db = sqlite3.open(freshPath);
        try {
          final tables = db
              .select("SELECT name FROM sqlite_master WHERE type = 'table'")
              .map((row) => row['name'] as String)
              .toSet();
          expect(
            tables,
            containsAll(<String>['远程', 'folder_order', 'folder_sync']),
          );
          final member = db.select('SELECT * FROM ${_quote('远程')}').single;
          expect(member['id'], '77');
          expect(member['name'], 'Remote Comic');
        } finally {
          db.dispose();
        }
      },
    );

    test('works without reload / warning callbacks', () async {
      createFavoritesDb(
        folders: <String, List<Map<String, Object?>>>{
          'A': <Map<String, Object?>>[_row(id: '1')],
        },
      );
      final store = await openStore();
      await store.emit(
        domain: SyncDomains.favoriteFolder,
        key: SyncKeys.favoriteFolderKey('A'),
        kind: SyncOpKind.add,
        data: <String, Object?>{'name': 'A'},
      );
      await store.emit(
        domain: SyncDomains.favoriteComic,
        key: SyncKeys.favoriteComicKey('A', '1', '1'),
        kind: SyncOpKind.add,
        data: _comicPayload(_row(id: '1')),
      );

      final adapter = FavoritesAdapter(dbPath: favoritesPath);
      await adapter.applyRemote(store);
      await adapter.reload();
      expect(rows('A'), hasLength(1));
    });
  });

  group('folder guard', () {
    test('accepts practical unicode folder names', () {
      for (final name in <String>[
        '默认',
        'Reading List',
        'a.b_c-d',
        '漫画 2026',
        'Ünïcode',
        'a' * maxFolderNameLength,
      ]) {
        expect(isValidFolderName(name), isTrue, reason: name);
      }
    });

    test('rejects unsafe folder names', () {
      for (final name in <String>[
        '',
        ' leading',
        'trailing ',
        'a/b',
        r'a\b',
        'a"b',
        'a\u0000b',
        'a\nb',
        'a\tb',
        'a;b',
        'a(b)',
        '😀',
        'x' * 0,
        'a' * (maxFolderNameLength + 1),
        'folder_order',
        'folder_sync',
        'sqlite_master',
        'x"; DROP TABLE "a"; --',
      ]) {
        expect(isValidFolderName(name), isFalse, reason: name);
      }
    });

    test('quotes identifiers and refuses unvalidated names', () {
      expect(quote('默认'), '"默认"');
      expect(quote('a"b'), '"a""b"');
      expect(quoteIdentifier('a"b'), '"a""b"');
      expect(safeIdentifier('Reading List'), '"Reading List"');
      expect(
        () => safeIdentifier('x"; DROP TABLE "a"; --'),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => assertSafe('bad/name'), throwsA(isA<ArgumentError>()));
      expect(() => assertSafe('good name'), returnsNormally);

      expect(FolderGuard.isValidFolderName('默认'), isTrue);
      expect(FolderGuard.safeIdentifier('A'), '"A"');
      expect(FolderGuard.maxLength, maxFolderNameLength);
    });
  });
}
