import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/sync/app/adapters/auth_adapter.dart';
import 'package:venera/sync/app/adapters/history_adapter.dart';
import 'package:venera/sync/app/adapters/read_later_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/app/sync_app_reconciler.dart';
import 'package:venera/sync/sync.dart';

const _device = 'aaaaaaaa-0000-0000-0000-0000000000aa';

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
) => [
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
