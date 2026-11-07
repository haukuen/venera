/// Projects the app cookie jar into the `auth` sync domain (protocol v2 §3.4).
///
/// The cookie DB is shared with `lib/network/cookie_jar.dart`:
///
/// ```sql
/// CREATE TABLE cookies (
///   name TEXT NOT NULL,
///   value TEXT NOT NULL,
///   domain TEXT NOT NULL,
///   path TEXT,
///   expires INTEGER,
///   secure INTEGER,
///   httpOnly INTEGER,
///   PRIMARY KEY (name, domain, path)
/// );
/// ```
///
/// Every cookie is one LWW register keyed by
/// `[cookieDomain, cookiePath, cookieName]`; deleting the cookie emits a
/// tombstone, so it is removed here when the store record is not visible any
/// more. The adapter opens its own SQLite connection lazily (call [dispose] to
/// release it) and is pure Dart, no Flutter imports.
library;

import 'package:sqlite3/sqlite3.dart';

import '../../domains.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

class AuthAdapter implements SyncAppAdapter, SyncDisposableAdapter {
  AuthAdapter({
    required String dbPath,
    Future<void> Function()? reload,
    void Function(String message)? onWarning,
  }) : _dbPath = dbPath,
       _reload = reload,
       _onWarning = onWarning;

  final String _dbPath;
  final Future<void> Function()? _reload;
  final void Function(String message)? _onWarning;

  static const Set<String> _domains = <String>{SyncDomains.auth};

  Database? _db;

  /// Closes the lazily opened database connection. The adapter can be reused
  /// afterwards (the next call reopens the file).
  @override
  void dispose() {
    final db = _db;
    _db = null;
    db?.dispose();
  }

  Database get _database {
    final existing = _db;
    if (existing != null) return existing;
    final db = sqlite3.open(_dbPath);
    // The app's CookieJarSql keeps its own connection open; wait for its lock
    // instead of failing with SQLITE_BUSY.
    db.execute('PRAGMA busy_timeout = 5000;');
    return _db = db;
  }

  @override
  Set<String> get domains => _domains;

  /// Reads every cookie row as an `auth` register.
  ///
  /// A `NULL` path (legacy rows) is projected as `/`, matching how the cookie
  /// jar treats it. Does not mutate the database.
  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final rows = _database.select('''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies;
    ''');
    final records = <AdapterRecord>[];
    for (final row in rows) {
      final name = row['name'];
      final domain = row['domain'];
      if (name is! String || name.isEmpty) {
        _warn('auth: skipping cookie row with invalid name');
        continue;
      }
      if (domain is! String || domain.isEmpty) {
        _warn('auth: skipping cookie "$name" with invalid domain');
        continue;
      }
      final value = row['value'];
      if (value is! String) {
        _warn('auth: skipping cookie "$domain/$name" with non-string value');
        continue;
      }
      final rawPath = row['path'];
      records.add(
        AdapterRecord(
          domain: SyncDomains.auth,
          key: SyncKeys.authCookieKey(
            domain,
            rawPath is String ? rawPath : '/',
            name,
          ),
          field: '',
          kind: SyncOpKind.upsert,
          data: <String, Object?>{
            'value': value,
            'expires': row['expires'] is int ? row['expires'] as int : null,
            'secure': row['secure'] is int ? row['secure'] as int : null,
            'httpOnly': row['httpOnly'] is int ? row['httpOnly'] as int : null,
          },
        ),
      );
    }
    return records;
  }

  /// Rewrites the cookie table to match the visible `auth` records of
  /// [store] in one transaction.
  ///
  /// Visible records are upserted; rows whose key is not visible (never seen,
  /// or tombstoned) are deleted. Malformed records are reported through
  /// [onWarning] and skipped. [reload] runs only when the table changed, so
  /// the app can rebuild its in-memory cookie jar.
  @override
  Future<void> applyRemote(SyncStore store) async {
    final stored = await store.dumpRecords(domains: _domains);

    final desired = <String, _CookieRow>{};
    for (final record in stored) {
      if (!record.visible) continue;
      if (record.field.isNotEmpty) {
        _warn(
          'auth: ignoring record with unexpected field '
          '"${record.field}" for ${record.key.encode()}',
        );
        continue;
      }
      final parts = record.key.parts;
      // Source login state shares the `auth` domain with a two-part key and is
      // owned by ComicSourceDataAdapter; skip it without a warning.
      if (SyncKeys.isSourceDataKey(parts)) continue;
      if (parts.length != 3) {
        _warn('auth: ignoring malformed key ${record.key.encode()}');
        continue;
      }
      final domain = parts[0];
      final path = parts[1];
      final name = parts[2];
      if (domain.isEmpty || name.isEmpty) {
        _warn(
          'auth: ignoring record with empty domain/name '
          '${record.key.encode()}',
        );
        continue;
      }
      final row = _parseCookie(
        record.data,
        domain: domain,
        path: path,
        name: name,
      );
      if (row == null) continue;
      desired[record.key.encode()] = row;
    }

    final db = _database;
    var changed = 0;
    db.execute('BEGIN IMMEDIATE;');
    try {
      final existing = <_ExistingCookie>[];
      final byKey = <String, _ExistingCookie>{};
      for (final row in db.select('''
        SELECT name, value, domain, path, expires, secure, httpOnly
        FROM cookies;
      ''')) {
        final name = row['name'];
        final domain = row['domain'];
        if (name is! String || domain is! String) {
          // Cannot compute the sync key for this row; leave it alone rather
          // than deleting data we do not understand.
          _warn('auth: keeping cookie row with invalid name/domain');
          continue;
        }
        final rawPath = row['path'];
        final cookie = _ExistingCookie(
          name: name,
          domain: domain,
          rawPath: rawPath is String ? rawPath : null,
          value: row['value'] is String ? row['value'] as String : null,
          expires: row['expires'] is int ? row['expires'] as int : null,
          secure: row['secure'] is int ? row['secure'] as int : null,
          httpOnly: row['httpOnly'] is int ? row['httpOnly'] as int : null,
        );
        existing.add(cookie);
        byKey[cookie.syncKey] = cookie;
      }

      // Delete every row the merged store no longer considers visible
      // (explicit tombstones and cookies this device never had a record for).
      for (final cookie in existing) {
        if (desired.containsKey(cookie.syncKey)) continue;
        _deleteExisting(db, cookie);
        changed++;
      }

      // Upsert visible records, skipping rows whose content is already equal
      // so a repeated apply is a true no-op.
      for (final entry in desired.entries) {
        final current = byKey[entry.key];
        if (current != null && current.sameContent(entry.value)) continue;
        if (current != null) {
          // A legacy NULL path never conflicts in the (name, domain, path)
          // primary key, so remove the old row explicitly before inserting.
          _deleteExisting(db, current);
        }
        final row = entry.value;
        db.execute(
          '''
          INSERT OR REPLACE INTO cookies
            (name, value, domain, path, expires, secure, httpOnly)
          VALUES (?, ?, ?, ?, ?, ?, ?);
        ''',
          <Object?>[
            row.name,
            row.value,
            row.domain,
            row.path,
            row.expires,
            row.secure,
            row.httpOnly,
          ],
        );
        changed++;
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }

    if (changed > 0) await _reload?.call();
  }

  @override
  Future<void> reload() async {
    await _reload?.call();
  }

  @override
  bool retainsMissingRecord(StoredRecord record) => false;

  @override
  Future<bool> retainsDomainRecords(SyncStore store, String domain) async =>
      false;

  void _warn(String message) => _onWarning?.call(message);

  void _deleteExisting(Database db, _ExistingCookie cookie) {
    if (cookie.rawPath == null) {
      db.execute(
        'DELETE FROM cookies WHERE name = ? AND domain = ? AND path IS NULL;',
        <Object?>[cookie.name, cookie.domain],
      );
    } else {
      db.execute(
        'DELETE FROM cookies WHERE name = ? AND domain = ? AND path = ?;',
        <Object?>[cookie.name, cookie.domain, cookie.rawPath],
      );
    }
  }

  _CookieRow? _parseCookie(
    Map<String, Object?>? data, {
    required String domain,
    required String path,
    required String name,
  }) {
    if (data == null) {
      _warn('auth: ignoring record without data for "$domain$path$name"');
      return null;
    }
    final value = data['value'];
    if (value is! String) {
      _warn(
        'auth: ignoring cookie "$name" of "$domain" with missing/'
        'non-string value',
      );
      return null;
    }
    return _CookieRow(
      name: name,
      value: value,
      domain: domain,
      path: path,
      expires: _optionalInt(data['expires'], 'expires', name),
      secure: _optionalFlag(data['secure'], 'secure', name),
      httpOnly: _optionalFlag(data['httpOnly'], 'httpOnly', name),
    );
  }

  /// Lenient numeric conversion: a bad optional field defaults to `null`
  /// instead of dropping the whole cookie (the login state is worth keeping).
  int? _optionalInt(Object? value, String field, String name) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    _warn('auth: ignoring invalid $field for cookie "$name"');
    return null;
  }

  /// Lenient boolean conversion, normalised to the SQLite `0`/`1` convention
  /// used by the cookie jar.
  int? _optionalFlag(Object? value, String field, String name) {
    if (value == null) return null;
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value == 0 ? 0 : 1;
    _warn('auth: ignoring invalid $field for cookie "$name"');
    return null;
  }
}

class _CookieRow {
  const _CookieRow({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.secure,
    required this.httpOnly,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final int? expires;
  final int? secure;
  final int? httpOnly;
}

/// A cookie row already stored in the business database, together with its raw
/// (possibly `NULL`) path so the exact row can be deleted again.
class _ExistingCookie {
  const _ExistingCookie({
    required this.name,
    required this.domain,
    required this.rawPath,
    required this.value,
    required this.expires,
    required this.secure,
    required this.httpOnly,
  });

  final String name;
  final String domain;
  final String? rawPath;
  final String? value;
  final int? expires;
  final int? secure;
  final int? httpOnly;

  /// Canonical sync key; a `NULL` path is projected as `/` like the cookie jar
  /// does.
  String get syncKey =>
      SyncKeys.authCookieKey(domain, rawPath ?? '/', name).encode();

  bool sameContent(_CookieRow other) =>
      value == other.value &&
      expires == other.expires &&
      secure == other.secure &&
      httpOnly == other.httpOnly;
}
