/// App adapter for the `history` domain (M1).
///
/// Projects the business `history` table into [AdapterRecord]s (one
/// [SyncFields.progress] register + one [SyncFields.meta] register per row) and
/// projects merged remote state back with a single SQLite transaction.
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

/// One merged history row, assembled from the visible store records.
class _MergedHistory {
  Map<String, Object?>? progress;
  Map<String, Object?>? meta;
}

/// Adapter for [SyncDomains.history].
///
/// [dbPath] is the business `history.db`. The adapter opens (and closes) its
/// own short-lived connection for every operation, so it never holds the
/// database open across manager/isolate writes.
class HistoryAdapter implements SyncAppAdapter {
  HistoryAdapter({
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
  Set<String> get domains => const <String>{SyncDomains.history};

  // ---------------------------------------------------------------------------
  // Local -> records
  // ---------------------------------------------------------------------------

  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final db = _open();
    try {
      if (!_tableExists(db, 'history')) {
        _warn('history table is missing; no local records projected');
        return const <AdapterRecord>[];
      }
      final records = <AdapterRecord>[];
      for (final row in db.select('SELECT * FROM history')) {
        try {
          final id = row['id'];
          final type = row['type'];
          if (id is! String || type is! int) {
            _warn('skipping malformed history row (id=$id, type=$type)');
            continue;
          }
          final key = SyncKeys.historyKey(id, type.toString());
          records.add(
            AdapterRecord(
              domain: SyncDomains.history,
              key: key,
              field: SyncFields.progress,
              kind: SyncOpKind.upsert,
              data: <String, Object?>{
                'ep': _intValue(row['ep'], 0),
                'page': _intValue(row['page'], 0),
                // Keep the database string representation (comma separated set)
                // instead of parsing it into a list.
                'readEpisode': _stringValue(row['readEpisode'], ''),
                'max_page': _nullableIntValue(row['max_page']),
                'chapter_group': _nullableIntValue(row['chapter_group']),
                'time': _intValue(row['time'], 0),
              },
            ),
          );
          records.add(
            AdapterRecord(
              domain: SyncDomains.history,
              key: key,
              field: SyncFields.meta,
              kind: SyncOpKind.upsert,
              data: <String, Object?>{
                'title': _stringValue(row['title'], ''),
                'subtitle': _nullableStringValue(row['subtitle']),
                'cover': _stringValue(row['cover'], ''),
              },
            ),
          );
        } catch (error) {
          _warn('skipping malformed history row: $error');
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
    // 1. Read the merged state and collapse both field groups per (id, type).
    final merged = <SyncKey, _MergedHistory>{};
    for (final record in await store.dumpRecords(domains: domains)) {
      try {
        if (record.domain != SyncDomains.history || !record.visible) continue;
        final parts = record.key.parts;
        if (parts.length != 2 || int.tryParse(parts[1]) == null) {
          _warn('skipping history record with malformed key ${record.key}');
          continue;
        }
        final entry = merged.putIfAbsent(record.key, _MergedHistory.new);
        if (record.field == SyncFields.progress) {
          final data = record.data;
          if (data == null) {
            _warn('progress record ${record.key} has no payload');
            continue;
          }
          entry.progress = data;
        } else if (record.field == SyncFields.meta) {
          final data = record.data;
          if (data == null) {
            _warn('meta record ${record.key} has no payload');
            continue;
          }
          entry.meta = data;
        } else {
          // Unknown field groups cannot be projected; keep the key present so a
          // future field group does not delete an existing business row.
          _warn('ignoring unknown history field "${record.field}"');
        }
      } catch (error) {
        _warn('skipping malformed history record: $error');
      }
    }

    // 2. Project into the business database atomically.
    final db = _open();
    try {
      if (!_tableExists(db, 'history')) {
        _warn('history table is missing; remote state not applied');
        return;
      }
      db.execute('BEGIN IMMEDIATE;');
      try {
        final existing = <SyncKey, Row>{};
        for (final row in db.select('SELECT * FROM history')) {
          final id = row['id'];
          final type = row['type'];
          if (id is String && type is int) {
            existing[SyncKeys.historyKey(id, type.toString())] = row;
          }
        }

        for (final entry in merged.entries) {
          try {
            _upsertRow(db, entry.key, entry.value, existing[entry.key]);
          } catch (error) {
            _warn('failed to apply history record ${entry.key}: $error');
          }
        }

        // Anything that is not visible in the store disappears locally. A
        // tombstone and a domain clear both show up as "no visible record".
        for (final key in existing.keys) {
          if (merged.containsKey(key)) continue;
          try {
            final type = int.tryParse(key.parts[1]);
            if (type == null) continue;
            db.execute('DELETE FROM history WHERE id = ? AND type = ?', [
              key.parts[0],
              type,
            ]);
          } catch (error) {
            _warn('failed to delete history record $key: $error');
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
    _MergedHistory merged,
    Row? existing,
  ) {
    final progress = merged.progress ?? const <String, Object?>{};
    final meta = merged.meta ?? const <String, Object?>{};
    final type = int.parse(key.parts[1]);

    final title = _pickString(meta, 'title', existing?['title'], '');
    final subtitle = _pickNullableString(
      meta,
      'subtitle',
      existing?['subtitle'],
    );
    final cover = _pickString(meta, 'cover', existing?['cover'], '');
    final time = _pickInt(progress, 'time', existing?['time'], 0);
    final ep = _pickInt(progress, 'ep', existing?['ep'], 0);
    final page = _pickInt(progress, 'page', existing?['page'], 0);
    final readEpisode = _pickReadEpisode(progress, existing?['readEpisode']);
    final maxPage = _pickNullableInt(
      progress,
      'max_page',
      existing?['max_page'],
    );
    final chapterGroup = _pickNullableInt(
      progress,
      'chapter_group',
      existing?['chapter_group'],
    );

    db.execute(
      'INSERT OR REPLACE INTO history '
      '(id, title, subtitle, cover, time, type, ep, page, readEpisode, '
      'max_page, chapter_group) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        key.parts[0],
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

  String _pickReadEpisode(Map<String, Object?> progress, Object? fallback) {
    if (progress.containsKey('readEpisode')) {
      final raw = progress['readEpisode'];
      if (raw is String) return raw;
      if (raw is List) {
        return raw.map((element) => '$element').join(',');
      }
    }
    if (fallback is String) return fallback;
    return '';
  }

  // ---------------------------------------------------------------------------
  // Value coercion (tolerant of SQLite dynamic typing / malformed payloads)
  // ---------------------------------------------------------------------------

  int _intValue(Object? value, int fallback) => _tryInt(value) ?? fallback;

  int? _nullableIntValue(Object? value) => _tryInt(value);

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
