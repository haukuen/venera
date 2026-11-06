import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/sync/app/adapters/auth_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceId = 'bbbbbbbb-1111-2222-3333-444444444444';

/// The exact schema used by `lib/network/cookie_jar.dart`.
const _cookiesSchema = '''
  CREATE TABLE IF NOT EXISTS cookies (
    name TEXT NOT NULL,
    value TEXT NOT NULL,
    domain TEXT NOT NULL,
    path TEXT,
    expires INTEGER,
    secure INTEGER,
    httpOnly INTEGER,
    PRIMARY KEY (name, domain, path)
  );
''';

void createCookieDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute(_cookiesSchema);
  } finally {
    db.dispose();
  }
}

void main() {
  late Directory dir;
  late String dbPath;
  late Database raw;
  late SqliteSyncStore store;
  late List<String> warnings;
  late int reloadCalls;
  late AuthAdapter adapter;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('venera-auth-adapter-');
    dbPath = '${dir.path}/cookie.db';
    createCookieDatabase(dbPath);
    raw = sqlite3.open(dbPath);
    store = await SqliteSyncStore.open(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceId,
    );
    warnings = <String>[];
    reloadCalls = 0;
    adapter = AuthAdapter(
      dbPath: dbPath,
      reload: () async {
        reloadCalls++;
      },
      onWarning: warnings.add,
    );
  });

  tearDown(() async {
    adapter.dispose();
    raw.dispose();
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void insertCookie({
    required String name,
    required String value,
    required String domain,
    String? path = '/',
    int? expires,
    int? secure = 0,
    int? httpOnly = 0,
  }) {
    raw.execute(
      '''
      INSERT INTO cookies (name, value, domain, path, expires, secure, httpOnly)
      VALUES (?, ?, ?, ?, ?, ?, ?);
    ''',
      <Object?>[name, value, domain, path, expires, secure, httpOnly],
    );
  }

  List<Map<String, Object?>> readAllCookies() {
    return raw
        .select('''
          SELECT name, value, domain, path, expires, secure, httpOnly
          FROM cookies
          ORDER BY domain, path, name;
        ''')
        .map(
          (row) => <String, Object?>{
            'name': row['name'],
            'value': row['value'],
            'domain': row['domain'],
            'path': row['path'],
            'expires': row['expires'],
            'secure': row['secure'],
            'httpOnly': row['httpOnly'],
          },
        )
        .toList();
  }

  Future<void> emitCookie(
    String domain,
    String path,
    String name, {
    String value = 'v',
    int? expires,
    Object? secure,
    Object? httpOnly,
    bool deleted = false,
  }) async {
    final key = SyncKeys.authCookieKey(domain, path, name);
    await store.emit(
      domain: SyncDomains.auth,
      key: key,
      kind: SyncOpKind.upsert,
      data: <String, Object?>{
        'value': value,
        'expires': expires,
        'secure': secure,
        'httpOnly': httpOnly,
      },
    );
    if (deleted) {
      await store.emit(
        domain: SyncDomains.auth,
        key: key,
        kind: SyncOpKind.del,
      );
    }
  }

  AdapterRecord? recordFor(
    List<AdapterRecord> records,
    String domain,
    String path,
    String name,
  ) {
    final encoded = SyncKeys.authCookieKey(domain, path, name).encode();
    for (final record in records) {
      if (record.key.encode() == encoded) return record;
    }
    return null;
  }

  group('readLocalRecords', () {
    test('projects cookies with opaque domain/path/name segments', () async {
      insertCookie(
        name: 'sid',
        value: 'abc',
        domain: 'example.com',
        expires: 1762345678000,
        secure: 1,
        httpOnly: 1,
      );
      insertCookie(
        name: 'theme',
        value: 'dark',
        domain: '.example.com',
        path: null,
        expires: null,
        secure: null,
        httpOnly: null,
      );
      insertCookie(
        name: 'weird@/name',
        value: 'v',
        domain: 'a.b',
        path: '/x/y',
      );

      final records = await adapter.readLocalRecords();

      expect(records, hasLength(3));
      for (final record in records) {
        expect(record.domain, SyncDomains.auth);
        expect(record.field, '');
        expect(record.kind, SyncOpKind.upsert);
      }

      final sid = recordFor(records, 'example.com', '/', 'sid')!;
      expect(sid.data, <String, Object?>{
        'value': 'abc',
        'expires': 1762345678000,
        'secure': 1,
        'httpOnly': 1,
      });

      // A NULL path is projected as '/'.
      final theme = recordFor(records, '.example.com', '/', 'theme')!;
      expect(theme.data, <String, Object?>{
        'value': 'dark',
        'expires': null,
        'secure': null,
        'httpOnly': null,
      });

      // Segments are not split on separators.
      final weird = recordFor(records, 'a.b', '/x/y', 'weird@/name')!;
      expect(weird.key.parts, <String>['a.b', '/x/y', 'weird@/name']);
      expect(weird.data!['value'], 'v');
    });

    test('empty table produces no records', () async {
      expect(await adapter.readLocalRecords(), isEmpty);
    });
  });

  group('applyRemote', () {
    test(
      'upserts visible cookies, deletes absent/tombstoned rows, reloads',
      () async {
        insertCookie(
          name: 'sid',
          value: 'old',
          domain: 'example.com',
          path: '/',
        );
        insertCookie(
          name: 'stale',
          value: 'x',
          domain: 'old.example.com',
          path: '/',
        );
        insertCookie(
          name: 'legacy',
          value: 'x',
          domain: 'legacy.example.com',
          path: null,
        );
        insertCookie(
          name: 'dead',
          value: 'x',
          domain: 'gone.example.com',
          path: '/',
        );
        await emitCookie(
          'example.com',
          '/',
          'sid',
          value: 'new',
          expires: 123,
          secure: 1,
          httpOnly: 0,
        );
        await emitCookie('.foo.com', '/', 'fresh', value: 'v2');
        await emitCookie('gone.example.com', '/', 'dead', deleted: true);

        await adapter.applyRemote(store);

        expect(reloadCalls, 1);
        expect(warnings, isEmpty);
        final rows = readAllCookies();
        expect(rows, hasLength(2));
        expect(rows[0], <String, Object?>{
          'name': 'fresh',
          'value': 'v2',
          'domain': '.foo.com',
          'path': '/',
          'expires': null,
          'secure': null,
          'httpOnly': null,
        });
        expect(rows[1], <String, Object?>{
          'name': 'sid',
          'value': 'new',
          'domain': 'example.com',
          'path': '/',
          'expires': 123,
          'secure': 1,
          'httpOnly': 0,
        });
      },
    );

    test('repeated apply is a no-op and does not reload again', () async {
      await emitCookie('example.com', '/', 'sid', value: 'v1', expires: 42);
      await adapter.applyRemote(store);
      expect(reloadCalls, 1);
      final first = readAllCookies();

      await adapter.applyRemote(store);

      expect(readAllCookies(), first);
      expect(reloadCalls, 1);
    });

    test('replaces a legacy NULL-path row instead of duplicating it', () async {
      insertCookie(
        name: 'sid',
        value: 'old',
        domain: 'example.com',
        path: null,
      );
      await emitCookie('example.com', '/', 'sid', value: 'new', expires: 7);

      await adapter.applyRemote(store);

      final rows = readAllCookies();
      expect(rows, hasLength(1));
      expect(rows.single['path'], '/');
      expect(rows.single['value'], 'new');
      expect(rows.single['expires'], 7);
      expect(reloadCalls, 1);
    });

    test('no-op when both the store and the table are empty', () async {
      await adapter.applyRemote(store);

      expect(readAllCookies(), isEmpty);
      expect(reloadCalls, 0);
      expect(warnings, isEmpty);
    });

    test('tolerates malformed records and keeps applying valid ones', () async {
      // Wrong number of key segments.
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKey(<String>['a', 'b']),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'x'},
      );
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKey(<String>['a', '/', 'b', 'extra']),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'x'},
      );
      // Missing / non-string value.
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.authCookieKey('d', '/', 'missingValue'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'expires': 1},
      );
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.authCookieKey('d', '/', 'badValue'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 123},
      );
      // Empty domain / name segments.
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.authCookieKey('', '/', 'emptyDomain'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'x'},
      );
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.authCookieKey('d', '/', ''),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'x'},
      );
      // Unexpected field group.
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.authCookieKey('d', '/', 'field'),
        field: 'meta',
        kind: SyncOpKind.upsert,
        data: <String, Object?>{'value': 'x'},
      );
      // Valid record: bool flags are normalised to 0/1.
      await emitCookie(
        'd',
        '/',
        'good',
        value: 'ok',
        expires: 5,
        secure: true,
        httpOnly: 0,
      );

      await adapter.applyRemote(store);

      expect(warnings, hasLength(7));
      expect(reloadCalls, 1);
      final rows = readAllCookies();
      expect(rows, hasLength(1));
      expect(rows.single, <String, Object?>{
        'name': 'good',
        'value': 'ok',
        'domain': 'd',
        'path': '/',
        'expires': 5,
        'secure': 1,
        'httpOnly': 0,
      });
    });

    test('bad optional fields keep the cookie with warnings', () async {
      await emitCookie('example.com', '/', 'sid', value: 'keep-me', secure: 1);
      // Overwrite the record with wrong optional types via a fresh upsert.
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.authCookieKey('example.com', '/', 'sid'),
        kind: SyncOpKind.upsert,
        data: <String, Object?>{
          'value': 'keep-me',
          'expires': 'tomorrow',
          'secure': 'yes',
          'httpOnly': 2,
        },
      );

      await adapter.applyRemote(store);

      expect(warnings, hasLength(2));
      final rows = readAllCookies();
      expect(rows, hasLength(1));
      expect(rows.single['value'], 'keep-me');
      expect(rows.single['expires'], isNull);
      expect(rows.single['secure'], isNull);
      // Non-zero numbers are true.
      expect(rows.single['httpOnly'], 1);
    });
  });

  test('read -> store -> apply roundtrips cookies across databases', () async {
    insertCookie(
      name: 'sid',
      value: 'abc',
      domain: 'example.com',
      expires: 1762345678000,
      secure: 1,
      httpOnly: 0,
    );
    insertCookie(
      name: 'theme',
      value: 'dark',
      domain: '.example.com',
      path: null,
    );

    final sourceRecords = await adapter.readLocalRecords();
    for (final record in sourceRecords) {
      await store.emit(
        domain: record.domain,
        key: record.key,
        field: record.field,
        kind: record.kind,
        data: record.data,
      );
    }

    final secondDbPath = '${dir.path}/cookie2.db';
    createCookieDatabase(secondDbPath);
    final second = AuthAdapter(dbPath: secondDbPath);
    try {
      await second.applyRemote(store);
      final targetRecords = await second.readLocalRecords();

      String describe(Iterable<AdapterRecord> records) {
        final entries = records.toList()
          ..sort((a, b) => a.key.encode().compareTo(b.key.encode()));
        return entries
            .map((record) => '${record.key.encode()}|${record.data}')
            .join('\n');
      }

      expect(describe(targetRecords), describe(sourceRecords));
    } finally {
      second.dispose();
    }
  });
}
