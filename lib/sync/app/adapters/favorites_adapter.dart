/// App adapter for the favorites domains (`favoriteFolder`, `favoriteOrder`,
/// `favoriteLink`, `favoriteComic`) of the v2 sync protocol (M1).
///
/// Business database: `local_favorite.db`. The app stores one SQLite table per
/// favorite folder plus two system tables (`folder_order`, `folder_sync`), so a
/// folder name is a *SQLite identifier*. Remote folder names are untrusted
/// input: every name is validated with `folder_guard.dart` before it is used
/// and every identifier is quoted. Invalid remote folder names are skipped with
/// a warning and never interpolated into SQL.
///
/// The adapter opens (and closes) its own short-lived SQLite connection for
/// every operation, so it never holds the business database open across
/// manager / isolate writes. This file is deliberately pure Dart
/// (`package:sqlite3` + `dart:io` only, no Flutter / app imports).
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../domains.dart';
import '../../key_codec.dart';
import '../../op.dart';
import '../../store.dart';
import '../folder_guard.dart';
import '../sync_app_adapter.dart';

/// A favorite member row, assembled from a `favoriteComic` payload.
///
/// The protocol stores `name` / `author` / `tags` / `cover` in the `meta` field
/// group; this adapter projects the whole business row into the membership add
/// payload (see [FavoritesAdapter.readLocalRecords]) so both stay in sync.
class _FavoriteMember {
  const _FavoriteMember({
    required this.id,
    required this.type,
    required this.name,
    required this.author,
    required this.tags,
    required this.coverPath,
    required this.time,
    required this.displayOrder,
    required this.translatedTags,
  });

  /// Builds a row from an untrusted store payload, tolerating missing or
  /// wrongly typed values (they fall back to empty / null).
  factory _FavoriteMember.fromPayload({
    required String id,
    required int type,
    Map<String, Object?>? payload,
  }) {
    final data = payload ?? const <String, Object?>{};
    return _FavoriteMember(
      id: id,
      type: type,
      name: _asString(data['name']),
      author: _asString(data['author']),
      tags: _asString(data['tags']),
      coverPath: _asString(data['cover_path']),
      time: _asString(data['time']),
      displayOrder: _asInt(data['display_order']),
      translatedTags: _asNullableString(data['translated_tags']),
    );
  }

  final String id;
  final int type;
  final String name;
  final String author;
  final String tags;
  final String coverPath;
  final String time;
  final int? displayOrder;
  final String? translatedTags;

  /// Values injected into the `local_favorite` folder-table columns.
  List<Object?> toColumns() => <Object?>[
    id,
    name,
    author,
    type,
    tags,
    coverPath,
    time,
    displayOrder,
    translatedTags,
  ];
}

/// Network source binding of a favorite folder (`favoriteLink` payload).
class _FolderLink {
  const _FolderLink({required this.sourceKey, required this.sourceFolder});

  final String sourceKey;
  final String? sourceFolder;
}

/// Parsed merged remote state of the four favorites domains.
class _RemoteState {
  /// Folder names present in the merged state (already validated).
  final Set<String> folders = <String>{};

  /// `folder -> memberKey -> member`.
  final Map<String, Map<String, _FavoriteMember>> members =
      <String, Map<String, _FavoriteMember>>{};

  /// `folder -> network binding` (already validated).
  final Map<String, _FolderLink> links = <String, _FolderLink>{};

  /// Folder order from the single `favoriteOrder` register; `null` means the
  /// merged store has no visible order record, so the local order is kept.
  List<String>? order;
}

/// Adapter for [SyncDomains.favoriteFolder], [SyncDomains.favoriteComic],
/// [SyncDomains.favoriteOrder] and [SyncDomains.favoriteLink].
class FavoritesAdapter implements SyncAppAdapter {
  FavoritesAdapter({
    required String dbPath,
    Future<void> Function()? reload,
    void Function(String message)? onWarning,
  }) : _dbPath = dbPath,
       _reload = reload,
       _onWarning = onWarning;

  /// Business database file (`local_favorite.db`).
  final String _dbPath;
  final Future<void> Function()? _reload;
  final void Function(String message)? _onWarning;

  /// Constant key of the single `favoriteOrder` register (§3: "单值").
  static final SyncKey orderKey = SyncKey(const <String>['order']);

  /// Schema of a favorite folder table (same as the app's `createFolder`).
  static const List<String> folderColumns = <String>[
    'id',
    'name',
    'author',
    'type',
    'tags',
    'cover_path',
    'time',
    'display_order',
    'translated_tags',
  ];

  static const String folderOrderTable = 'folder_order';
  static const String folderSyncTable = 'folder_sync';

  static const List<String> systemTables = <String>[
    folderOrderTable,
    folderSyncTable,
  ];

  @override
  Set<String> get domains => const <String>{
    SyncDomains.favoriteFolder,
    SyncDomains.favoriteComic,
    SyncDomains.favoriteOrder,
    SyncDomains.favoriteLink,
  };

  // ---------------------------------------------------------------------------
  // Business DB -> records
  // ---------------------------------------------------------------------------

  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final file = File(_dbPath);
    if (!file.existsSync()) {
      // The favorites manager creates the database lazily on first launch.
      // Project an empty order register instead of no order record at all so
      // the service does not treat the missing record as a delete.
      return <AdapterRecord>[_orderRecord(const <String>[])];
    }
    final db = _open();
    try {
      final tables = _readTableNames(db);
      final folders = _folderTables(tables);
      final order = tables.contains(folderOrderTable)
          ? _readFolderOrder(db)
          : <String, int>{};
      final links = tables.contains(folderSyncTable)
          ? _readFolderLinks(db)
          : <String, _FolderLink>{};

      final records = <AdapterRecord>[];
      for (final folder in folders) {
        records.add(_folderRecord(folder));
        final link = links[folder];
        if (link != null) records.add(_linkRecord(folder, link));
        records.addAll(_memberRecords(db, folder));
      }
      records.add(_orderRecord(_orderedFolders(folders, order)));
      return records;
    } finally {
      db.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Records -> business DB
  // ---------------------------------------------------------------------------

  @override
  Future<void> applyRemote(SyncStore store) async {
    // 1. Parse the merged, visible remote state of our four domains.
    final stored = (await store.dumpRecords(
      domains: domains,
    )).toList(growable: false);
    final hasLinkRecords = stored.any(
      (record) => record.domain == SyncDomains.favoriteLink,
    );
    final state = _collectRemoteState(stored);

    // 2. Project it into the business database in one transaction.
    final db = _open(createParent: true);
    try {
      db.execute('BEGIN IMMEDIATE;');
      try {
        _applyRemoteState(db, state, hasLinkRecords: hasLinkRecords);
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
  // Parsing merged store records
  // ---------------------------------------------------------------------------

  _RemoteState _collectRemoteState(List<StoredRecord> records) {
    final state = _RemoteState();
    final warnedNames = <String>{};
    for (final record in records) {
      if (!record.visible) continue;
      try {
        switch (record.domain) {
          case SyncDomains.favoriteFolder:
            // Membership lives in the empty field group; other field groups
            // (e.g. the protocol's `meta` register) carry no folder-set data
            // for this schema.
            if (record.field.isNotEmpty) continue;
            final folder = _folderFromKey(
              record.key,
              parts: 1,
              domain: record.domain,
              warnedNames: warnedNames,
            );
            if (folder != null) state.folders.add(folder);
          case SyncDomains.favoriteComic:
            if (record.field.isNotEmpty) continue;
            final parts = record.key.parts;
            if (parts.length != 3) {
              _warn(
                'skipping favoriteComic record with malformed key '
                '${record.key}',
              );
              continue;
            }
            final folder = _guardedFolder(
              parts[0],
              domain: record.domain,
              warnedNames: warnedNames,
            );
            if (folder == null) continue;
            final type = int.tryParse(parts[2]);
            if (type == null) {
              _warn(
                'skipping favoriteComic record with non-integer type '
                '${jsonEncode(parts[2])}',
              );
              continue;
            }
            state.folders.add(folder);
            final members = state.members.putIfAbsent(
              folder,
              () => <String, _FavoriteMember>{},
            );
            members[_memberKey(parts[1], type)] = _FavoriteMember.fromPayload(
              id: parts[1],
              type: type,
              payload: record.data,
            );
          case SyncDomains.favoriteLink:
            if (record.field.isNotEmpty) continue;
            final folder = _folderFromKey(
              record.key,
              parts: 1,
              domain: record.domain,
              warnedNames: warnedNames,
            );
            if (folder == null) continue;
            final data = record.data ?? const <String, Object?>{};
            final sourceKey = data['source_key'];
            if (sourceKey is! String || sourceKey.isEmpty) {
              _warn(
                'skipping favoriteLink record for ${jsonEncode(folder)}: '
                'missing source_key',
              );
              continue;
            }
            final sourceFolder = data['source_folder'];
            state.links[folder] = _FolderLink(
              sourceKey: sourceKey,
              sourceFolder: sourceFolder is String ? sourceFolder : null,
            );
          case SyncDomains.favoriteOrder:
            if (record.field.isNotEmpty) continue;
            state.order = _parseFolderOrder(record.data);
          default:
            // dumpRecords(domains: ...) already filters to our domains.
            _warn('ignoring unexpected favorites domain "${record.domain}"');
        }
      } catch (error) {
        _warn('skipping malformed ${record.domain} record: $error');
      }
    }
    return state;
  }

  /// Reads the folder name segment of a `[folder]`-shaped key.
  String? _folderFromKey(
    SyncKey key, {
    required int parts,
    required String domain,
    required Set<String> warnedNames,
  }) {
    if (key.parts.length != parts) {
      _warn('skipping $domain record with malformed key $key');
      return null;
    }
    return _guardedFolder(
      key.parts.first,
      domain: domain,
      warnedNames: warnedNames,
    );
  }

  /// Validates an untrusted folder name, warning once per distinct name.
  String? _guardedFolder(
    String name, {
    required String domain,
    required Set<String> warnedNames,
  }) {
    if (isValidFolderName(name)) return name;
    if (warnedNames.add(name)) {
      _warn(
        'skipping invalid favorite folder name ${jsonEncode(name)} '
        'from $domain (not used as a SQL identifier)',
      );
    }
    return null;
  }

  /// Parses the `favoriteOrder` register payload.
  ///
  /// Returns `null` when the payload is malformed so the local folder order is
  /// left untouched instead of being wiped.
  List<String>? _parseFolderOrder(Map<String, Object?>? data) {
    final raw = data?['folders'];
    if (raw is! List) {
      _warn('ignoring favoriteOrder record without a folders array');
      return null;
    }
    final folders = <String>[];
    final warned = <String>{};
    for (final item in raw) {
      if (item is String && isValidFolderName(item)) {
        folders.add(item);
        continue;
      }
      final rendered = item is String ? jsonEncode(item) : '$item';
      if (warned.add(rendered)) {
        _warn('skipping invalid folder name in favoriteOrder: $rendered');
      }
    }
    return folders;
  }

  // ---------------------------------------------------------------------------
  // Applying merged state
  // ---------------------------------------------------------------------------

  void _applyRemoteState(
    Database db,
    _RemoteState state, {
    required bool hasLinkRecords,
  }) {
    final tables = _readTableNames(db);

    // The sync side tables are part of the business schema; create them when
    // the database is new (e.g. a fresh install pulling remote favorites).
    db.execute(
      'CREATE TABLE IF NOT EXISTS $folderOrderTable ('
      'folder_name TEXT PRIMARY KEY, order_value INTEGER)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS $folderSyncTable ('
      'folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT)',
    );

    final existingFolders = _folderTables(tables);
    final existing = existingFolders.toSet();

    // 3a. Create tables for folders that only exist remotely.
    for (final folder in state.folders) {
      if (existing.contains(folder)) continue;
      db.execute(_createFolderTableSql(safeIdentifier(folder)));
      existing.add(folder);
    }

    // 3b. Upsert visible members and delete rows that are no longer visible.
    for (final folder in state.folders) {
      _syncFolderMembers(db, folder, state.members[folder] ?? const {});
    }

    // 3c. Drop folder tables that are no longer part of the merged state.
    // Only tables whose name passes the guard are managed; local tables with
    // invalid names are out of scope and intentionally left alone.
    for (final folder in existingFolders) {
      if (state.folders.contains(folder)) continue;
      db.execute('DROP TABLE ${safeIdentifier(folder)}');
    }

    // 3d. Folder order: the single register wins as a whole array (§3).
    final order = state.order;
    if (order != null) {
      _replaceFolderOrder(db, order);
    }

    // 3e. Network links: mirror the visible link records once the store knows
    // the domain (a store that never saw `favoriteLink` must not wipe local
    // bindings before the service seeded it).
    if (hasLinkRecords) {
      final desired = <String, _FolderLink>{};
      for (final entry in state.links.entries) {
        if (!state.folders.contains(entry.key)) continue;
        desired[entry.key] = entry.value;
      }
      _replaceFolderLinks(db, desired);
    }
  }

  /// Upserts [desired] member rows into one folder table and deletes rows that
  /// are not part of the merged visible set.
  void _syncFolderMembers(
    Database db,
    String folder,
    Map<String, _FavoriteMember> desired,
  ) {
    final table = safeIdentifier(folder);
    final existing = <String, Map<String, Object?>>{};
    for (final row in db.select('SELECT * FROM $table')) {
      final id = row['id'];
      final type = row['type'];
      if (id is! String || type is! int) continue;
      existing[_memberKey(id, type)] = <String, Object?>{
        'id': id,
        'type': type,
        'name': row['name'],
        'author': row['author'],
        'tags': row['tags'],
        'cover_path': row['cover_path'],
        'time': row['time'],
        'display_order': row['display_order'],
        'translated_tags': row['translated_tags'],
      };
    }

    // Use upsert instead of INSERT OR REPLACE: the app adds extension columns
    // (last_update_time / has_new_update / last_check_time) to follow-up
    // folders via ALTER TABLE; REPLACE would delete the row and reset them.
    final insertSql =
        'INSERT INTO $table (${folderColumns.join(', ')}) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id, type) DO UPDATE SET '
        'name = excluded.name, author = excluded.author, '
        'tags = excluded.tags, cover_path = excluded.cover_path, '
        'time = excluded.time, display_order = excluded.display_order, '
        'translated_tags = excluded.translated_tags';
    for (final entry in desired.entries) {
      final member = entry.value;
      final current = existing[entry.key];
      if (current != null && _memberMatches(current, member)) continue;
      db.execute(insertSql, member.toColumns());
    }

    for (final entry in existing.entries) {
      if (desired.containsKey(entry.key)) continue;
      db.execute('DELETE FROM $table WHERE id = ? AND type = ?', [
        entry.value['id'],
        entry.value['type'],
      ]);
    }
  }

  /// Replaces `folder_order` with the merged order array.
  void _replaceFolderOrder(Database db, List<String> folders) {
    final desired = <String, int>{};
    for (final folder in folders) {
      desired.putIfAbsent(folder, () => desired.length);
    }
    final current = <String, int>{};
    for (final row in db.select(
      'SELECT folder_name, order_value FROM $folderOrderTable',
    )) {
      final name = row['folder_name'];
      final value = row['order_value'];
      if (name is String && value is int) current[name] = value;
    }
    if (_sameOrder(current, desired)) return;
    db.execute('DELETE FROM $folderOrderTable');
    for (final entry in desired.entries) {
      db.execute(
        'INSERT INTO $folderOrderTable (folder_name, order_value) '
        'VALUES (?, ?)',
        [entry.key, entry.value],
      );
    }
  }

  /// Replaces `folder_sync` with the merged visible link records.
  void _replaceFolderLinks(Database db, Map<String, _FolderLink> desired) {
    final current = <String, _FolderLink>{};
    for (final row in db.select(
      'SELECT folder_name, source_key, source_folder FROM $folderSyncTable',
    )) {
      final name = row['folder_name'];
      final sourceKey = row['source_key'];
      if (name is! String || sourceKey is! String) continue;
      final sourceFolder = row['source_folder'];
      current[name] = _FolderLink(
        sourceKey: sourceKey,
        sourceFolder: sourceFolder is String ? sourceFolder : null,
      );
    }
    if (_sameLinks(current, desired)) return;
    db.execute('DELETE FROM $folderSyncTable');
    for (final entry in desired.entries) {
      db.execute(
        'INSERT INTO $folderSyncTable '
        '(folder_name, source_key, source_folder) VALUES (?, ?, ?)',
        [entry.key, entry.value.sourceKey, entry.value.sourceFolder],
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Local database helpers
  // ---------------------------------------------------------------------------

  Database _open({bool createParent = false}) {
    if (createParent) {
      final parent = File(_dbPath).parent;
      if (parent.path.isNotEmpty && !parent.existsSync()) {
        parent.createSync(recursive: true);
      }
    }
    final db = sqlite3.open(_dbPath);
    try {
      db.execute('PRAGMA busy_timeout = 5000;');
    } catch (_) {
      db.dispose();
      rethrow;
    }
    return db;
  }

  Set<String> _readTableNames(Database db) {
    final names = <String>{};
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )) {
      final name = row['name'];
      if (name is String) names.add(name);
    }
    return names;
  }

  /// Folder tables of the business DB: every table except the system tables and
  /// the `sqlite_*` internals, sorted by name, keeping only names that pass the
  /// guard (invalid local table names are local-only and never managed).
  List<String> _folderTables(Set<String> tables) {
    final folders = tables.toList()..sort();
    final result = <String>[];
    for (final name in folders) {
      if (systemTables.contains(name) || name.startsWith('sqlite_')) continue;
      if (!isValidFolderName(name)) {
        _warn(
          'ignoring local favorites table with invalid folder name '
          '${jsonEncode(name)}',
        );
        continue;
      }
      result.add(name);
    }
    return result;
  }

  Map<String, int> _readFolderOrder(Database db) {
    final order = <String, int>{};
    for (final row in db.select(
      'SELECT folder_name, order_value FROM $folderOrderTable',
    )) {
      final name = row['folder_name'];
      final value = row['order_value'];
      if (name is String && value is int) order[name] = value;
    }
    return order;
  }

  Map<String, _FolderLink> _readFolderLinks(Database db) {
    final links = <String, _FolderLink>{};
    for (final row in db.select(
      'SELECT folder_name, source_key, source_folder FROM $folderSyncTable',
    )) {
      final name = row['folder_name'];
      final sourceKey = row['source_key'];
      if (name is! String || sourceKey is! String) continue;
      final sourceFolder = row['source_folder'];
      links[name] = _FolderLink(
        sourceKey: sourceKey,
        sourceFolder: sourceFolder is String ? sourceFolder : null,
      );
    }
    return links;
  }

  /// Folder tables ordered by `folder_order.order_value`.
  ///
  /// Mirrors `LocalFavoritesManager.folderNames`: a folder without an order row
  /// falls back to `0`, and ties are broken by name so the projection is
  /// deterministic.
  List<String> _orderedFolders(List<String> folders, Map<String, int> order) {
    final ordered = folders.toList();
    ordered.sort((a, b) {
      final byValue = (order[a] ?? 0).compareTo(order[b] ?? 0);
      if (byValue != 0) return byValue;
      return a.compareTo(b);
    });
    return ordered;
  }

  List<AdapterRecord> _memberRecords(Database db, String folder) {
    final records = <AdapterRecord>[];
    for (final row in db.select(
      'SELECT * FROM ${safeIdentifier(folder)} ORDER BY display_order, id',
    )) {
      final id = row['id'];
      final type = row['type'];
      if (id is! String || type is! int) {
        _warn(
          'skipping malformed favorite row in folder ${jsonEncode(folder)} '
          '(id=$id, type=$type)',
        );
        continue;
      }
      records.add(
        AdapterRecord(
          domain: SyncDomains.favoriteComic,
          key: SyncKeys.favoriteComicKey(folder, id, type.toString()),
          kind: SyncOpKind.add,
          data: <String, Object?>{
            'name': row['name'],
            'author': row['author'],
            'tags': row['tags'],
            'cover_path': row['cover_path'],
            'time': row['time'],
            'display_order': row['display_order'],
            'translated_tags': row['translated_tags'],
          },
        ),
      );
    }
    return records;
  }

  AdapterRecord _folderRecord(String folder) => AdapterRecord(
    domain: SyncDomains.favoriteFolder,
    key: SyncKeys.favoriteFolderKey(folder),
    kind: SyncOpKind.add,
    data: <String, Object?>{'name': folder},
  );

  AdapterRecord _linkRecord(String folder, _FolderLink link) => AdapterRecord(
    domain: SyncDomains.favoriteLink,
    key: SyncKeys.favoriteLinkKey(folder),
    kind: SyncOpKind.upsert,
    data: <String, Object?>{
      'source_key': link.sourceKey,
      'source_folder': link.sourceFolder,
    },
  );

  AdapterRecord _orderRecord(List<String> folders) => AdapterRecord(
    domain: SyncDomains.favoriteOrder,
    key: orderKey,
    kind: SyncOpKind.upsert,
    data: <String, Object?>{'folders': folders},
  );

  String _createFolderTableSql(String quotedFolder) =>
      'CREATE TABLE IF NOT EXISTS $quotedFolder ('
      'id TEXT, name TEXT, author TEXT, type INTEGER, tags TEXT, '
      'cover_path TEXT, time TEXT, display_order INTEGER, '
      'translated_tags TEXT, PRIMARY KEY (id, type))';

  bool _memberMatches(Map<String, Object?> current, _FavoriteMember member) {
    return current['name'] == member.name &&
        current['author'] == member.author &&
        current['tags'] == member.tags &&
        current['cover_path'] == member.coverPath &&
        current['time'] == member.time &&
        current['display_order'] == member.displayOrder &&
        current['translated_tags'] == member.translatedTags;
  }

  bool _sameOrder(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool _sameLinks(Map<String, _FolderLink> a, Map<String, _FolderLink> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null ||
          other.sourceKey != entry.value.sourceKey ||
          other.sourceFolder != entry.value.sourceFolder) {
        return false;
      }
    }
    return true;
  }

  /// Key for deduplicating member rows inside one folder table.
  String _memberKey(String id, int type) => '$id\u0000$type';

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

// -----------------------------------------------------------------------------
// Payload value coercion (tolerant of SQLite dynamic typing / malformed input)
// -----------------------------------------------------------------------------

String _asString(Object? value) {
  if (value is String) return value;
  if (value is num) return '$value';
  return '';
}

String? _asNullableString(Object? value) {
  if (value is String) return value;
  if (value is num) return '$value';
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
