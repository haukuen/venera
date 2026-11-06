/// App adapter for the `readLater` domain (M1).
///
/// Projects the business `read_later` table into [AdapterRecord]s (set
/// membership, one [SyncOpKind.add] record per row) and projects merged remote
/// state back with a single SQLite transaction.
///
/// This file is deliberately pure Dart (`package:sqlite3` only, no Flutter and
/// no app/business imports) so it can be exercised with temp databases in
/// `flutter test` and reused by any backend.
library;

import 'package:sqlite3/sqlite3.dart';

import '../../domains.dart';
import '../../key_codec.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

/// Adapter for [SyncDomains.readLater].
///
/// [dbPath] is the business `read_later.db`. The adapter opens (and closes) its
/// own short-lived connection for every operation, so it never holds the
/// database open across manager/isolate writes.
class ReadLaterAdapter implements SyncAppAdapter {
  ReadLaterAdapter({
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
  Set<String> get domains => const <String>{SyncDomains.readLater};

  // ---------------------------------------------------------------------------
  // Local -> records
  // ---------------------------------------------------------------------------

  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final db = _open();
    try {
      if (!_tableExists(db, 'read_later')) {
        _warn('read_later table is missing; no local records projected');
        return const <AdapterRecord>[];
      }
      final records = <AdapterRecord>[];
      for (final row in db.select('SELECT * FROM read_later')) {
        try {
          final id = row['id'];
          final type = row['type'];
          if (id is! String || type is! int) {
            _warn('skipping malformed read_later row (id=$id, type=$type)');
            continue;
          }
          records.add(
            AdapterRecord(
              domain: SyncDomains.readLater,
              key: SyncKeys.readLaterKey(id, type.toString()),
              field: SyncFields.empty,
              kind: SyncOpKind.add,
              data: <String, Object?>{
                'title': _stringValue(row['title'], ''),
                'subtitle': _nullableStringValue(row['subtitle']),
                'cover': _stringValue(row['cover'], ''),
                'source_key': _stringValue(row['source_key'], ''),
                'added_time': _intValue(row['added_time'], 0),
              },
            ),
          );
        } catch (error) {
          _warn('skipping malformed read_later row: $error');
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
    // 1. Read the merged state; set membership means one visible payload per key.
    final merged = <SyncKey, Map<String, Object?>>{};
    for (final record in await store.dumpRecords(domains: domains)) {
      try {
        if (record.domain != SyncDomains.readLater || !record.visible) continue;
        final parts = record.key.parts;
        if (parts.length != 2 || int.tryParse(parts[1]) == null) {
          _warn('skipping readLater record with malformed key ${record.key}');
          continue;
        }
        if (record.field != SyncFields.empty) {
          _warn('ignoring unknown readLater field "${record.field}"');
        }
        merged.putIfAbsent(
          record.key,
          () => record.data ?? const <String, Object?>{},
        );
      } catch (error) {
        _warn('skipping malformed readLater record: $error');
      }
    }

    // 2. Project into the business database atomically.
    final db = _open();
    try {
      if (!_tableExists(db, 'read_later')) {
        _warn('read_later table is missing; remote state not applied');
        return;
      }
      db.execute('BEGIN IMMEDIATE;');
      try {
        final existing = <SyncKey, Row>{};
        for (final row in db.select('SELECT * FROM read_later')) {
          final id = row['id'];
          final type = row['type'];
          if (id is String && type is int) {
            existing[SyncKeys.readLaterKey(id, type.toString())] = row;
          }
        }

        for (final entry in merged.entries) {
          try {
            _upsertRow(db, entry.key, entry.value, existing[entry.key]);
          } catch (error) {
            _warn('failed to apply readLater record ${entry.key}: $error');
          }
        }

        // A tombstone (del) or a domain clear removes the key from the visible
        // set, so the business row is deleted here.
        for (final key in existing.keys) {
          if (merged.containsKey(key)) continue;
          try {
            final type = int.tryParse(key.parts[1]);
            if (type == null) continue;
            db.execute('DELETE FROM read_later WHERE id = ? AND type = ?', [
              key.parts[0],
              type,
            ]);
          } catch (error) {
            _warn('failed to delete readLater record $key: $error');
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

  // ---------------------------------------------------------------------------
  // Business row mapping
  // ---------------------------------------------------------------------------

  void _upsertRow(
    Database db,
    SyncKey key,
    Map<String, Object?> payload,
    Row? existing,
  ) {
    final type = int.parse(key.parts[1]);
    final title = _pickString(payload, 'title', existing?['title'], '');
    final subtitle = _pickNullableString(
      payload,
      'subtitle',
      existing?['subtitle'],
    );
    final cover = _pickString(payload, 'cover', existing?['cover'], '');
    final sourceKey = _pickString(
      payload,
      'source_key',
      existing?['source_key'],
      '',
    );
    final addedTime = _pickInt(
      payload,
      'added_time',
      existing?['added_time'],
      0,
    );

    db.execute(
      'INSERT OR REPLACE INTO read_later '
      '(id, type, title, subtitle, cover, source_key, added_time) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [key.parts[0], type, title, subtitle, cover, sourceKey, addedTime],
    );
  }

  String _pickString(
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

  int _pickInt(
    Map<String, Object?> payload,
    String name,
    Object? fallback,
    int defaultValue,
  ) {
    if (payload.containsKey(name)) {
      final parsed = _tryInt(payload[name]);
      if (parsed != null) return parsed;
    }
    return _tryInt(fallback) ?? defaultValue;
  }

  // ---------------------------------------------------------------------------
  // Value coercion (tolerant of SQLite dynamic typing / malformed payloads)
  // ---------------------------------------------------------------------------

  int _intValue(Object? value, int fallback) => _tryInt(value) ?? fallback;

  int? _tryInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String _stringValue(Object? value, String fallback) {
    if (value is String) return value;
    if (value is num) return '$value';
    return fallback;
  }

  String? _nullableStringValue(Object? value) {
    if (value is String) return value;
    if (value is num) return '$value';
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
