/// App adapter for the `imageFavorite` domain (M3).
///
/// Projects the business `image_favorites` table (stored inside `history.db`)
/// into one row-level register record per row and projects merged remote state
/// back with a single SQLite transaction.
///
/// ## Pragmatic row-level mapping
///
/// The v2 protocol models `imageFavorite` as page set elements keyed by
/// `[comicKey, ep, page]` plus comic/chapter level metadata registers (§3), but
/// Venera stores image favorites as a *per-comic aggregate*: every row of
/// `image_favorites` already contains the whole chapter/page structure
/// (`image_favorites_ep` JSON) and the comic metadata. Splitting that into
/// protocol-native page elements would require a lossy re-encoding of the
/// aggregate and a migration decision outside M3.
///
/// M3 therefore uses a pragmatic row-level last-writer-wins register keyed by
/// `SyncKey([id, source_key])` (the business primary key) with the empty field
/// group [SyncFields.empty]. The whole row (including the exact JSON strings of
/// `image_favorites_ep` / `other`) is one register value. This keeps local
/// aggregation semantics intact and is fully convergent between v2 peers that
/// use this adapter, but it is **not** interoperable with protocol-native
/// `[comicKey, ep, page]` records — a future M3+ migration can add the native
/// projection without touching the business managers.
///
/// This file is deliberately pure Dart (`package:sqlite3` only, no Flutter /
/// app imports) so it can be exercised with temp databases in `flutter test`
/// and reused by any backend.
library;

import 'package:sqlite3/sqlite3.dart';

import '../../domains.dart';
import '../../key_codec.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

/// Business columns carried by the row-level register, in table order.
const List<String> _columns = <String>[
  'id',
  'title',
  'sub_title',
  'author',
  'tags',
  'translated_tags',
  'time',
  'max_page',
  'source_key',
  'image_favorites_ep',
  'other',
];

/// Columns inserted by [ImageFavoriteAdapter.applyRemote], in table order.
const String _insertSql =
    'INSERT OR REPLACE INTO image_favorites '
    '(id, title, sub_title, author, tags, translated_tags, time, max_page, '
    'source_key, image_favorites_ep, other) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/// Adapter for [SyncDomains.imageFavorite].
///
/// [dbPath] is the business `history.db` (the `image_favorites` table lives
/// there). The adapter opens (and closes) its own short-lived SQLite
/// connection for every operation, so it never holds the database open across
/// manager / isolate writes.
class ImageFavoriteAdapter implements SyncAppAdapter {
  ImageFavoriteAdapter({
    required String dbPath,
    Future<void> Function()? reload,
    void Function(String message)? onWarning,
  }) : _dbPath = dbPath,
       _reload = reload,
       _onWarning = onWarning;

  final String _dbPath;
  final Future<void> Function()? _reload;
  final void Function(String message)? _onWarning;

  @override
  Set<String> get domains => const <String>{SyncDomains.imageFavorite};

  // ---------------------------------------------------------------------------
  // Local -> records
  // ---------------------------------------------------------------------------

  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final db = _open();
    try {
      if (!_tableExists(db, 'image_favorites')) {
        _warn('image_favorites table is missing; no local records projected');
        return const <AdapterRecord>[];
      }
      final records = <AdapterRecord>[];
      for (final row in db.select('SELECT * FROM image_favorites')) {
        try {
          final id = row['id'];
          final sourceKey = row['source_key'];
          if (id is! String || sourceKey is! String) {
            _warn(
              'skipping malformed image_favorites row '
              '(id=$id, source_key=$sourceKey)',
            );
            continue;
          }
          final data = <String, Object?>{};
          for (final column in _columns) {
            final value = row[column];
            // JSON payloads must be encodable by the sync wire format. BLOBs
            // (or any future non JSON type) would make the store throw, so
            // skip the whole row instead of poisoning the batch.
            if (value == null || value is String || value is num) {
              data[column] = value;
            } else {
              throw FormatException(
                'column "$column" has unsupported type ${value.runtimeType}',
              );
            }
          }
          records.add(
            AdapterRecord(
              domain: SyncDomains.imageFavorite,
              // Pragmatic row-level register key: business primary key
              // (see the library docs above).
              key: SyncKey(<String>[id, sourceKey]),
              field: SyncFields.empty,
              kind: SyncOpKind.upsert,
              data: data,
            ),
          );
        } catch (error) {
          _warn('skipping malformed image_favorites row: $error');
        }
      }
      return records;
    } finally {
      db.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Records -> local
  // ---------------------------------------------------------------------------

  @override
  Future<void> applyRemote(SyncStore store) async {
    // 1. Read the visible merged state (row-level registers, empty field group).
    final desired = <SyncKey, Map<String, Object?>>{};
    for (final record in await store.dumpRecords(domains: domains)) {
      try {
        if (record.domain != SyncDomains.imageFavorite || !record.visible) {
          continue;
        }
        final parts = record.key.parts;
        if (parts.length != 2) {
          _warn(
            'ignoring imageFavorite record with malformed key '
            '${record.key.encode()}',
          );
          continue;
        }
        if (record.field != SyncFields.empty) {
          _warn(
            'ignoring imageFavorite record with unexpected field '
            '"${record.field}" for ${record.key.encode()}',
          );
          continue;
        }
        final data = record.data;
        if (data == null) {
          _warn('imageFavorite record ${record.key.encode()} has no payload');
          continue;
        }
        desired.putIfAbsent(record.key, () => data);
      } catch (error) {
        _warn('skipping malformed imageFavorite record: $error');
      }
    }

    // 2. Project into the business database atomically.
    final db = _open();
    try {
      if (!_tableExists(db, 'image_favorites')) {
        _warn('image_favorites table is missing; remote state not applied');
        return;
      }
      db.execute('BEGIN IMMEDIATE;');
      try {
        final existing = <SyncKey, Row>{};
        for (final row in db.select('SELECT * FROM image_favorites')) {
          final id = row['id'];
          final sourceKey = row['source_key'];
          if (id is String && sourceKey is String) {
            existing[SyncKey(<String>[id, sourceKey])] = row;
          }
        }

        for (final entry in desired.entries) {
          try {
            _upsertRow(db, entry.key, entry.value, existing[entry.key]);
          } catch (error) {
            _warn('failed to apply imageFavorite record ${entry.key}: $error');
          }
        }

        // A key not visible in the store (never seen, tombstoned, or covered by
        // a clear cutoff) is removed locally.
        for (final key in existing.keys) {
          if (desired.containsKey(key)) continue;
          try {
            db.execute(
              'DELETE FROM image_favorites WHERE id = ? AND source_key = ?',
              [key.parts[0], key.parts[1]],
            );
          } catch (error) {
            _warn('failed to delete imageFavorite record $key: $error');
          }
        }

        db.execute('COMMIT;');
      } catch (_) {
        try {
          db.execute('ROLLBACK;');
        } catch (_) {
          // Ignore rollback failures: the original error is more useful.
        }
        rethrow;
      }
    } finally {
      db.dispose();
    }

    await reload();
  }

  @override
  Future<void> reload() async {
    final callback = _reload;
    if (callback != null) {
      await callback();
    }
  }

  @override
  bool retainsMissingRecord(StoredRecord record) => false;

  // ---------------------------------------------------------------------------
  // Business row mapping
  // ---------------------------------------------------------------------------

  void _upsertRow(
    Database db,
    SyncKey key,
    Map<String, Object?> payload,
    Row? existing,
  ) {
    // The key is the identity: it wins over a conflicting payload id/source_key
    // so an upsert can never orphan the row from its delete key.
    final id = key.parts[0];
    final sourceKey = key.parts[1];

    final title = _pickRequiredString(payload, 'title', existing?['title'], '');
    final subTitle = _pickNullableString(
      payload,
      'sub_title',
      existing?['sub_title'],
    );
    final author = _pickNullableString(payload, 'author', existing?['author']);
    final tags = _pickNullableString(payload, 'tags', existing?['tags']);
    final translatedTags = _pickNullableString(
      payload,
      'translated_tags',
      existing?['translated_tags'],
    );
    final time = _pickNullableInt(payload, 'time', existing?['time']);
    final maxPage = _pickNullableInt(
      payload,
      'max_page',
      existing?['max_page'],
    );
    // NOT NULL JSON columns: keep the exact string when present, otherwise fall
    // back to the existing row, then to a valid empty JSON document.
    final imageFavoritesEp = _pickRequiredString(
      payload,
      'image_favorites_ep',
      existing?['image_favorites_ep'],
      '[]',
    );
    final other = _pickRequiredString(
      payload,
      'other',
      existing?['other'],
      '{}',
    );

    db.execute(_insertSql, [
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
    ]);
  }

  String _pickRequiredString(
    Map<String, Object?> payload,
    String name,
    Object? fallback,
    String defaultValue,
  ) {
    final raw = payload[name];
    if (raw is String) return raw;
    if (raw is num) return '$raw';
    if (fallback is String) return fallback;
    if (fallback is num) return '$fallback';
    return defaultValue;
  }

  String? _pickNullableString(
    Map<String, Object?> payload,
    String name,
    Object? fallback,
  ) {
    if (payload.containsKey(name)) {
      final raw = payload[name];
      if (raw is String) return raw;
      if (raw is num) return '$raw';
      return null;
    }
    if (fallback is String) return fallback;
    if (fallback is num) return '$fallback';
    return null;
  }

  int? _pickNullableInt(
    Map<String, Object?> payload,
    String name,
    Object? fallback,
  ) {
    if (payload.containsKey(name)) {
      return _tryInt(payload[name]);
    }
    return _tryInt(fallback);
  }

  int? _tryInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  // ---------------------------------------------------------------------------
  // SQLite plumbing
  // ---------------------------------------------------------------------------

  Database _open() {
    final db = sqlite3.open(_dbPath);
    db.execute('PRAGMA busy_timeout = 5000;');
    return db;
  }

  bool _tableExists(Database db, String table) {
    final rows = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  void _warn(String message) {
    final callback = _onWarning;
    if (callback == null) return;
    try {
      callback(message);
    } catch (_) {
      // A warning callback must never break the adapter.
    }
  }
}
