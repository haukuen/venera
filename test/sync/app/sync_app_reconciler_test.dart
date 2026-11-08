import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/sync/app/adapters/auth_adapter.dart';
import 'package:venera/sync/app/adapters/favorites_adapter.dart';
import 'package:venera/sync/app/adapters/history_adapter.dart';
import 'package:venera/sync/app/adapters/read_later_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/app/sync_app_reconciler.dart';
import 'package:venera/sync/sync.dart';

const _device = 'aaaaaaaa-0000-0000-0000-0000000000aa';

// Adapters that hold long-lived connections (AuthAdapter) must be disposed
// before the temp directory can be deleted on Windows.
final List<SyncAppAdapter> _createdAdapters = <SyncAppAdapter>[];

void _trackAdapters(Iterable<SyncAppAdapter> adapters) =>
    _createdAdapters.addAll(adapters);

void main() {
  late Directory tempDir;
  late _Paths paths;
  late SqliteSyncStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('venera_reconcile_');
    paths = _Paths(tempDir.path);
    _createHistoryDb(paths.history, const []);
    _createReadLaterDb(paths.readLater, const []);
    _createCookieDb(paths.cookies, const []);
    store = await SqliteSyncStore.open(
      dbPath: '${tempDir.path}/sync.db',
      deviceId: _device,
    );
  });

  tearDown(() async {
    await store.close();
    for (final adapter in _createdAdapters) {
      if (adapter is! SyncDisposableAdapter) continue;
      (adapter as SyncDisposableAdapter).dispose();
    }
    _createdAdapters.clear();
    tempDir.deleteSync(recursive: true);
  });

  test('reconcileLocal projects business rows and is idempotent', () async {
    _createHistoryDb(paths.history, [
      _HistoryRow(id: 'c1', type: 1, ep: 2, page: 3, title: 'Comic 1'),
    ]);
    _createReadLaterDb(paths.readLater, [
      _ReadLaterRow(id: 'c1', type: 1, title: 'Comic 1'),
    ]);
    final settings = <String, Object?>{'theme_mode': 'dark'};
    final reloads = <String>[];
    final reconciler = SyncAppReconciler(
      adapters: _adapters(paths, settings, reloads),
      enabledDomains: {
        SyncDomains.history,
        SyncDomains.readLater,
        SyncDomains.setting,
        SyncDomains.auth,
      },
      clearableDomains: {SyncDomains.history, SyncDomains.readLater},
    );

    await reconciler.reconcileLocal(store);
    final firstPending = await store.pendingCount();
    expect(firstPending, greaterThan(0));

    final progress = await store.recordOf(
      SyncDomains.history,
      SyncKeys.historyKey('c1', '1'),
      SyncFields.progress,
    );
    expect(progress, isNotNull);
    expect(progress!.visible, isTrue);
    expect(progress.data!['ep'], 2);
    expect(progress.data!['page'], 3);

    final readLater = await store.recordOf(
      SyncDomains.readLater,
      SyncKeys.readLaterKey('c1', '1'),
      '',
    );
    expect(readLater, isNotNull);
    expect(readLater!.visible, isTrue);

    final setting = await store.recordOf(
      SyncDomains.setting,
      SyncKeys.settingKey('theme_mode'),
      '',
    );
    expect(setting!.data!['value'], 'dark');

    // Nothing changed -> no additional ops.
    await reconciler.reconcileLocal(store);
    expect(await store.pendingCount(), firstPending);
  });

  test('reconcileLocal emits deletes and clear cutoffs', () async {
    _createHistoryDb(paths.history, [
      _HistoryRow(id: 'c1', type: 1, ep: 2, title: 'Comic 1'),
      _HistoryRow(id: 'c2', type: 1, ep: 1, title: 'Comic 2'),
    ]);
    final settings = <String, Object?>{};
    final reloads = <String>[];
    final reconciler = SyncAppReconciler(
      adapters: _adapters(paths, settings, reloads),
      enabledDomains: {SyncDomains.history},
      clearableDomains: {SyncDomains.history},
    );
    await reconciler.reconcileLocal(store);
    final inserted = await store.pendingCount();

    // Remove one row -> delete op.
    final db = sqlite3.open(paths.history);
    db.execute("DELETE FROM history WHERE id = 'c1';");
    db.dispose();
    await reconciler.reconcileLocal(store);
    final deleted = await store.recordOf(
      SyncDomains.history,
      SyncKeys.historyKey('c1', '1'),
      SyncFields.progress,
    );
    expect(deleted!.visible, isFalse);
    expect(await store.pendingCount(), greaterThanOrEqualTo(inserted));

    // Empty the table -> clear cutoff instead of per-record deletes.
    final db2 = sqlite3.open(paths.history);
    db2.execute('DELETE FROM history;');
    db2.dispose();
    await reconciler.reconcileLocal(store);
    final clears = await store.dumpClears(domains: {SyncDomains.history});
    expect(clears, isNotEmpty);
    final visible = [
      for (final record in await store.dumpRecords(
        domains: {SyncDomains.history},
      ))
        if (record.visible) record,
    ];
    expect(visible, isEmpty);
  });

  test('applyRemote writes merged records into business DBs', () async {
    _createHistoryDb(paths.history, []);
    _createReadLaterDb(paths.readLater, []);
    final settings = <String, Object?>{};
    final reloads = <String>[];
    final adapters = _adapters(paths, settings, reloads);
    final reconciler = SyncAppReconciler(
      adapters: adapters,
      enabledDomains: {
        SyncDomains.history,
        SyncDomains.readLater,
        SyncDomains.setting,
        SyncDomains.auth,
      },
      clearableDomains: {SyncDomains.history, SyncDomains.readLater},
    );

    await store.emit(
      domain: SyncDomains.history,
      key: SyncKeys.historyKey('remote', '1'),
      field: SyncFields.progress,
      kind: SyncOpKind.upsert,
      data: {'ep': 7, 'page': 1, 'time': 1},
    );
    await store.emit(
      domain: SyncDomains.history,
      key: SyncKeys.historyKey('remote', '1'),
      field: SyncFields.meta,
      kind: SyncOpKind.upsert,
      data: {'title': 'Remote', 'subtitle': '', 'cover': ''},
    );
    await store.emit(
      domain: SyncDomains.setting,
      key: SyncKeys.settingKey('theme_mode'),
      kind: SyncOpKind.upsert,
      data: {'value': 'light'},
    );
    await store.emit(
      domain: SyncDomains.auth,
      key: SyncKeys.authCookieKey('example.com', '/', 'sid'),
      kind: SyncOpKind.upsert,
      data: {'value': 'abc', 'expires': null, 'secure': 0, 'httpOnly': 1},
    );

    await reconciler.applyRemote(store);

    final db = sqlite3.open(paths.history);
    final rows = db.select('SELECT * FROM history;');
    db.dispose();
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'remote');
    expect(rows.single['ep'], 7);
    expect(rows.single['title'], 'Remote');

    expect(settings['theme_mode'], 'light');
    expect(reloads, isNotEmpty);

    final cookieDb = sqlite3.open(paths.cookies);
    final cookies = cookieDb.select('SELECT * FROM cookies;');
    cookieDb.dispose();
    expect(cookies, hasLength(1));
    expect(cookies.single['value'], 'abc');
  });

  test('applyRemote never clears data from an empty store', () async {
    _createCookieDb(paths.cookies, [
      _CookieRow(domain: 'example.com', name: 'sid', value: 'keep'),
    ]);
    final settings = <String, Object?>{};
    final reloads = <String>[];
    final reconciler = SyncAppReconciler(
      adapters: _adapters(paths, settings, reloads),
      enabledDomains: {SyncDomains.auth},
      clearableDomains: const {},
    );

    await reconciler.applyRemote(store);

    final cookieDb = sqlite3.open(paths.cookies);
    final cookies = cookieDb.select('SELECT * FROM cookies;');
    cookieDb.dispose();
    expect(cookies, hasLength(1));
    expect(cookies.single['value'], 'keep');
  });

  test('dataEquals handles maps/lists', () {
    expect(
      SyncAppReconciler.dataEquals(
        {
          'a': 1,
          'b': [1, 2],
        },
        {
          'b': [1, 2],
          'a': 1,
        },
      ),
      isTrue,
    );
    expect(SyncAppReconciler.dataEquals({'a': 1}, {'a': 2}), isFalse);
    expect(SyncAppReconciler.dataEquals(null, null), isTrue);
  });

  group('retains untrustworthy local projections', () {
    SyncAppReconciler historyReconciler() => SyncAppReconciler(
      adapters: _adapters(paths, <String, Object?>{}, <String>[]),
      enabledDomains: {SyncDomains.history},
      clearableDomains: {SyncDomains.history},
    );

    Future<List<StoredRecord>> visibleRecords(Set<String> domains) async => [
      for (final record in await store.dumpRecords(domains: domains))
        if (record.visible) record,
    ];

    test('a missing history table keeps records and skips the clear', () async {
      _createHistoryDb(paths.history, [
        _HistoryRow(id: 'c1', type: 1, ep: 2, title: 'Comic 1'),
        _HistoryRow(id: 'c2', type: 1, ep: 1, title: 'Comic 2'),
      ]);
      final reconciler = historyReconciler();
      await reconciler.reconcileLocal(store);

      // The manager recreates a fresh file when history.db goes missing: the
      // table is gone, and its emptiness must not read as a user deletion.
      final db = sqlite3.open(paths.history);
      db.execute('DROP TABLE history;');
      db.dispose();

      final retained = await reconciler.reconcileLocal(store);
      expect(retained, {SyncDomains.history});
      expect(await store.dumpClears(domains: {SyncDomains.history}), isEmpty);
      expect(await visibleRecords({SyncDomains.history}), hasLength(4));
    });

    test('deletions resume once the projection is readable again', () async {
      _createHistoryDb(paths.history, [
        _HistoryRow(id: 'c1', type: 1, ep: 2, title: 'Comic 1'),
        _HistoryRow(id: 'c2', type: 1, ep: 1, title: 'Comic 2'),
      ]);
      final reconciler = historyReconciler();
      await reconciler.reconcileLocal(store);

      // A row removed through the manager while the table stays readable is
      // a normal deletion and must keep propagating.
      final db = sqlite3.open(paths.history);
      db.execute("DELETE FROM history WHERE id = 'c1';");
      db.dispose();
      expect(await reconciler.reconcileLocal(store), isEmpty);
      final deleted = await store.recordOf(
        SyncDomains.history,
        SyncKeys.historyKey('c1', '1'),
        SyncFields.progress,
      );
      expect(deleted!.visible, isFalse);
    });

    test('a business database identity mismatch keeps records', () async {
      _createHistoryDb(paths.history, [
        _HistoryRow(id: 'c1', type: 1, ep: 2, title: 'Comic 1'),
      ]);
      final reconciler = historyReconciler();
      await reconciler.reconcileLocal(store);

      // The store remembers a projected file identity that the current file
      // cannot present (the file was recreated since).
      await store.setMeta('businessToken:history.db', '424242');
      expect(await reconciler.reconcileLocal(store), {SyncDomains.history});

      // Once the file presents the same identity again, trust is restored.
      final db = sqlite3.open(paths.history);
      db.execute('PRAGMA user_version = 424242;');
      db.dispose();
      expect(await reconciler.reconcileLocal(store), isEmpty);
    });

    test('a recreated favorites database is kept and then restored', () async {
      _createFavoritesDb(paths.favorites, folders: const ['A']);
      final favoritesAdapter = FavoritesAdapter(
        dbPath: paths.favorites,
        reload: () async {},
      );
      _trackAdapters([favoritesAdapter]);
      final reconciler = SyncAppReconciler(
        adapters: [favoritesAdapter],
        enabledDomains: favoritesAdapter.domains.toSet(),
      );
      await reconciler.reconcileLocal(store);
      expect(await visibleRecords(favoritesAdapter.domains), isNotEmpty);

      // Deleting the database file must not tombstone the collection.
      File(paths.favorites).deleteSync();
      final retained = await reconciler.reconcileLocal(store);
      expect(retained, favoritesAdapter.domains);
      expect(await visibleRecords(favoritesAdapter.domains), isNotEmpty);

      // Re-projecting restores the file, its content and the identity.
      await reconciler.applyRemote(store);
      expect(File(paths.favorites).existsSync(), isTrue);
      final db = sqlite3.open(paths.favorites);
      final tables = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'A';",
      );
      final fileToken = db.select('PRAGMA user_version;').first.values.first;
      db.dispose();
      expect(tables, isNotEmpty);
      expect(fileToken, isNot(0));
      expect(await reconciler.reconcileLocal(store), isEmpty);
    });

    test('any adapter claiming a domain can trigger retention', () async {
      _createCookieDb(paths.cookies, [
        _CookieRow(domain: 'example.com', name: 'sid', value: 'v'),
      ]);
      final authAdapter = AuthAdapter(
        dbPath: paths.cookies,
        reload: () async {},
      );
      _trackAdapters([authAdapter]);
      final reconciler = SyncAppReconciler(
        adapters: [
          // AuthAdapter is registered first and reports a readable (empty,
          // after the wipe below) projection; the second adapter claims the
          // same auth domain and vetoes deletion detection. With
          // first-adapter-wins semantics it would never be consulted.
          authAdapter,
          _RetainingAuthAdapter(),
        ],
        enabledDomains: {SyncDomains.auth},
      );
      await reconciler.reconcileLocal(store);

      final db = sqlite3.open(paths.cookies);
      db.execute('DELETE FROM cookies;');
      db.dispose();

      expect(await reconciler.reconcileLocal(store), {SyncDomains.auth});
      expect(await visibleRecords({SyncDomains.auth}), hasLength(1));
    });

    test(
      'a throwing adapter is isolated: its domain retained, others not',
      () async {
        _createHistoryDb(paths.history, [
          _HistoryRow(id: 'c1', type: 1, ep: 2, title: 'Comic 1'),
          _HistoryRow(id: 'c2', type: 1, ep: 1, title: 'Comic 2'),
        ]);
        _createCookieDb(paths.cookies, [
          _CookieRow(domain: 'example.com', name: 'sid', value: 'keep'),
        ]);
        final authAdapter = AuthAdapter(
          dbPath: paths.cookies,
          reload: () async {},
        );
        _trackAdapters([authAdapter]);
        // Seed the store from healthy projections first.
        final seeding = SyncAppReconciler(
          adapters: [
            HistoryAdapter(dbPath: paths.history, reload: () async {}),
            authAdapter,
          ],
          enabledDomains: {SyncDomains.history, SyncDomains.auth},
        );
        await seeding.reconcileLocal(store);

        // The auth projection becomes unreadable (corrupt database) and a
        // normal history deletion happens at the same time. The broken adapter
        // must not abort the whole reconciliation, must not tombstone its own
        // domain, and must not retain the *other* domains.
        final warnings = <String>[];
        final reconciler = SyncAppReconciler(
          adapters: [
            HistoryAdapter(dbPath: paths.history, reload: () async {}),
            _ThrowingAdapter({SyncDomains.auth}),
          ],
          enabledDomains: {SyncDomains.history, SyncDomains.auth},
          clearableDomains: {SyncDomains.history},
          onWarning: warnings.add,
        );
        final db = sqlite3.open(paths.cookies);
        db.execute('DELETE FROM cookies;');
        db.dispose();
        final historyDb = sqlite3.open(paths.history);
        historyDb.execute("DELETE FROM history WHERE id = 'c1';");
        historyDb.dispose();

        expect(await reconciler.reconcileLocal(store), {SyncDomains.auth});
        expect(warnings, hasLength(1));

        final cookie = await store.recordOf(
          SyncDomains.auth,
          SyncKeys.authCookieKey('example.com', '/', 'sid'),
          '',
        );
        expect(
          cookie!.visible,
          isTrue,
          reason: 'an unreadable projection must never read as a logout',
        );
        final history = await store.recordOf(
          SyncDomains.history,
          SyncKeys.historyKey('c1', '1'),
          SyncFields.progress,
        );
        expect(
          history!.visible,
          isFalse,
          reason: 'healthy domains keep detecting deletions',
        );
      },
    );
  });
}

class _RetainingAuthAdapter implements SyncAppAdapter {
  @override
  Set<String> get domains => {SyncDomains.auth};

  @override
  Future<List<AdapterRecord>> readLocalRecords() async =>
      const <AdapterRecord>[];

  @override
  Future<void> applyRemote(SyncStore store) async {}

  @override
  Future<void> reload() async {}

  @override
  bool retainsMissingRecord(StoredRecord record) => false;

  @override
  Future<bool> retainsDomainRecords(SyncStore store, String domain) async =>
      true;
}

/// An adapter whose projection throws (corrupt/unopenable business database).
/// It deliberately does *not* use the retention hooks: the reconciler must
/// treat a thrown [readLocalRecords] as "unreadable" on its own.
class _ThrowingAdapter implements SyncAppAdapter {
  _ThrowingAdapter(this._domains);

  final Set<String> _domains;

  @override
  Set<String> get domains => _domains;

  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    throw StateError('simulated unreadable business database');
  }

  @override
  Future<void> applyRemote(SyncStore store) async {}

  @override
  Future<void> reload() async {}

  // The defaults, spelled out: the reconciler must not rely on these hooks
  // for a thrown readLocalRecords — only the throw itself marks the adapter
  // as unreadable.
  @override
  bool retainsMissingRecord(StoredRecord record) => false;

  @override
  Future<bool> retainsDomainRecords(SyncStore store, String domain) async =>
      false;
}

void _createFavoritesDb(String path, {required List<String> folders}) {
  final db = sqlite3.open(path);
  db.execute(
    'CREATE TABLE IF NOT EXISTS folder_order '
    '(folder_name TEXT PRIMARY KEY, order_value INTEGER)',
  );
  db.execute(
    'CREATE TABLE IF NOT EXISTS folder_sync '
    '(folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT)',
  );
  for (final folder in folders) {
    db.execute(
      'CREATE TABLE "${folder.replaceAll('"', '""')}" ('
      'id TEXT, name TEXT, author TEXT, type INTEGER, tags TEXT, '
      'cover_path TEXT, time TEXT, display_order INTEGER, '
      'translated_tags TEXT, PRIMARY KEY (id, type))',
    );
  }
  db.dispose();
}

class _Paths {
  _Paths(String dir)
    : history = '$dir/history.db',
      readLater = '$dir/read_later.db',
      favorites = '$dir/local_favorite.db',
      cookies = '$dir/cookie.db';
  final String history;
  final String readLater;
  final String favorites;
  final String cookies;
}

List<SyncAppAdapter> _adapters(
  _Paths paths,
  Map<String, Object?> settings,
  List<String> reloads,
) {
  final adapters = <SyncAppAdapter>[
    HistoryAdapter(
      dbPath: paths.history,
      reload: () async => reloads.add('history'),
    ),
    ReadLaterAdapter(
      dbPath: paths.readLater,
      reload: () async => reloads.add('readLater'),
    ),
    AuthAdapter(dbPath: paths.cookies, reload: () async => reloads.add('auth')),
    _SettingsAdapterForTest(
      settings: settings,
      reload: () async => reloads.add('settings'),
    ),
  ];
  _trackAdapters(adapters);
  return adapters;
}

class _SettingsAdapterForTest implements SyncAppAdapter {
  _SettingsAdapterForTest({
    required this.settings,
    Future<void> Function()? reload,
  }) : _reload = reload;

  final Map<String, Object?> settings;
  final Future<void> Function()? _reload;

  @override
  Set<String> get domains => {SyncDomains.setting};

  @override
  Future<List<AdapterRecord>> readLocalRecords() async => [
    for (final entry in settings.entries)
      if (entry.value != null)
        AdapterRecord(
          domain: SyncDomains.setting,
          key: SyncKeys.settingKey(entry.key),
          data: {'value': entry.value},
        ),
  ];

  @override
  Future<void> applyRemote(SyncStore store) async {
    for (final record in await store.dumpRecords(
      domains: {SyncDomains.setting},
    )) {
      if (!record.visible || !record.domain.contains('setting')) continue;
      final key = record.key.parts.first;
      settings[key] = record.data?['value'];
    }
    await _reload?.call();
  }

  @override
  Future<void> reload() async {}

  @override
  bool retainsMissingRecord(StoredRecord record) => false;

  @override
  Future<bool> retainsDomainRecords(SyncStore store, String domain) async =>
      false;
}

class _HistoryRow {
  _HistoryRow({
    required this.id,
    required this.type,
    required this.ep,
    this.page = 0,
    required this.title,
  });
  final String id;
  final int type;
  final int ep;
  final int page;
  final String title;
}

void _createHistoryDb(String path, List<_HistoryRow> rows) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE IF NOT EXISTS history (
      id text, title text, subtitle text, cover text, time int, type int,
      ep int, page int, readEpisode text, max_page int, chapter_group int,
      primary key (id, type)
    );
  ''');
  for (final row in rows) {
    db.execute(
      'INSERT OR REPLACE INTO history (id,title,subtitle,cover,time,type,ep,page,readEpisode,max_page,chapter_group) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [
        row.id,
        row.title,
        '',
        '',
        1,
        row.type,
        row.ep,
        row.page,
        '${row.ep}:${row.page}',
        10,
        null,
      ],
    );
  }
  db.dispose();
}

class _ReadLaterRow {
  _ReadLaterRow({required this.id, required this.type, required this.title});
  final String id;
  final int type;
  final String title;
}

void _createReadLaterDb(String path, List<_ReadLaterRow> rows) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE IF NOT EXISTS read_later (
      id TEXT NOT NULL, type INTEGER NOT NULL, title TEXT NOT NULL,
      subtitle TEXT, cover TEXT NOT NULL, source_key TEXT NOT NULL,
      added_time INTEGER NOT NULL, PRIMARY KEY (id, type)
    );
  ''');
  for (final row in rows) {
    db.execute(
      'INSERT OR REPLACE INTO read_later (id,type,title,subtitle,cover,source_key,added_time) VALUES (?,?,?,?,?,?,?)',
      [row.id, row.type, row.title, '', '', 'test', 1],
    );
  }
  db.dispose();
}

class _CookieRow {
  _CookieRow({required this.domain, required this.name, required this.value});
  final String domain;
  final String name;
  final String value;
}

void _createCookieDb(String path, List<_CookieRow> rows) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE IF NOT EXISTS cookies (
      name TEXT NOT NULL, value TEXT NOT NULL, domain TEXT NOT NULL,
      path TEXT, expires INTEGER, secure INTEGER, httpOnly INTEGER,
      PRIMARY KEY (name, domain, path)
    );
  ''');
  for (final row in rows) {
    db.execute(
      'INSERT OR REPLACE INTO cookies (name,value,domain,path,expires,secure,httpOnly) VALUES (?,?,?,?,?,?,?)',
      [row.name, row.value, row.domain, '/', null, 0, 0],
    );
  }
  db.dispose();
}
