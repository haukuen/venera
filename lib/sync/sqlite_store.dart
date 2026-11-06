/// SQLite-backed [SyncStore] implementation for the v2 sync protocol.
///
/// This file is deliberately pure Dart (`package:sqlite3` + `dart:io` only) so
/// it can be exercised with `flutter test` and reused by any backend.
///
/// Design notes (protocol doc §4/§5):
///  - every write goes through a `BEGIN IMMEDIATE` transaction, so HLC/seq
///    read-modify-write cycles are serialized even across several connections
///    opened on the same database file;
///  - the merged record, the outbox row and the persisted counters are always
///    committed together; a crash therefore cannot produce a record without its
///    op nor an op without its version;
///  - pending outbox rows are coalesced *in place* (same `seq`), so the pending
///    range stays contiguous and is never punched with holes;
///  - [pendingOps] freezes the batch it hands out (`frozenUpTo` in `sync_meta`),
///    so a local emit racing an in-flight upload appends a fresh seq instead of
///    rewriting a row that may already be on the wire (protocol §7.2).
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' hide Version;

import 'hlc.dart';
import 'key_codec.dart';
import 'op.dart';
import 'snapshot.dart';
import 'store.dart';
import 'version.dart';

/// Meta keys persisted in `sync_meta`.
const String _metaDeviceId = 'deviceId';
const String _metaHlcMs = 'hlcMs';
const String _metaHlcCounter = 'hlcCounter';
const String _metaNextSeq = 'nextSeq';
const String _metaLastPush = 'lastPush';
const String _metaLastSnapshot = 'lastSnapshot';
const String _metaFrozenUpTo = 'frozenUpTo';

/// Key used for `clear` rows in the outbox (`k` is `'*'` on the wire).
const String _clearKey = '*';

/// Outbox/meta schema. `sync_reg` additionally carries the merged `data`
/// payload: the contract exposes [StoredRecord.data] and snapshot generation
/// needs the full local value, so the JSON payload lives next to the version
/// columns (business tables are intentionally untouched).
const List<String> _schemaStatements = [
  '''
CREATE TABLE IF NOT EXISTS sync_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
''',
  '''
CREATE TABLE IF NOT EXISTS sync_outbox (
  seq INTEGER PRIMARY KEY,
  hlc TEXT NOT NULL,
  d TEXT NOT NULL,
  k TEXT NOT NULL,
  f TEXT NOT NULL DEFAULT '',
  op TEXT NOT NULL,
  payload TEXT
)
''',
  // Coalescing looks up the newest pending op for a (domain, key, field), but
  // it must be possible to keep the frozen (possibly in-flight) row *and* a
  // fresh appended row for the same (d, k, f), so the index is not unique.
  // Drop the short-lived unique index for databases created by earlier builds.
  'DROP INDEX IF EXISTS sync_outbox_dkf',
  'CREATE INDEX IF NOT EXISTS sync_outbox_dkf ON sync_outbox (d, k, f)',
  '''
CREATE TABLE IF NOT EXISTS sync_applied (
  device TEXT PRIMARY KEY,
  seq INTEGER NOT NULL,
  hlc TEXT
)
''',
  '''
CREATE TABLE IF NOT EXISTS sync_seen (
  device TEXT NOT NULL,
  lo INTEGER NOT NULL,
  hi INTEGER NOT NULL,
  etag TEXT,
  appliedAt INTEGER NOT NULL,
  PRIMARY KEY (device, lo, hi)
)
''',
  '''
CREATE TABLE IF NOT EXISTS sync_reg (
  d TEXT NOT NULL,
  k TEXT NOT NULL,
  f TEXT NOT NULL DEFAULT '',
  hlc TEXT NOT NULL,
  seq INTEGER NOT NULL,
  deletedHlc TEXT,
  deletedSeq INTEGER,
  data TEXT,
  PRIMARY KEY (d, k, f)
)
''',
  '''
CREATE TABLE IF NOT EXISTS sync_clear (
  d TEXT PRIMARY KEY,
  cutoffHlc TEXT NOT NULL,
  cutoffSeq INTEGER NOT NULL
)
''',
  // Per-connection "applying remote" marker. The store uses explicit emit
  // calls, so no trigger depends on it, but keeping the flag makes the
  // connection state observable and mirrors protocol §4/§5.3.
  '''
CREATE TEMP TABLE IF NOT EXISTS sync_txn_flag (
  key TEXT PRIMARY KEY,
  value TEXT
)
''',
  '''
CREATE TABLE IF NOT EXISTS sync_conflict_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  d TEXT NOT NULL,
  k TEXT NOT NULL,
  f TEXT NOT NULL,
  localHlc TEXT,
  remoteHlc TEXT NOT NULL,
  at INTEGER NOT NULL
)
''',
];

enum _Outcome { applied, stale, duplicate }

class _DbRecord {
  const _DbRecord({
    required this.version,
    required this.deletedVersion,
    required this.dataJson,
  });

  final Version version;
  final Version? deletedVersion;
  final String? dataJson;
}

class _OutboxRow {
  const _OutboxRow({required this.seq, required this.hlc});

  final int seq;
  final String hlc;
}

/// SQLite implementation of [SyncStore].
///
/// Open it with [init] (or the [open] convenience factory) before use.
class SqliteSyncStore implements SyncStore {
  SqliteSyncStore({
    required String dbPath,
    required String deviceId,
    DateTime Function()? now,
  }) : _dbPath = dbPath,
       _deviceId = deviceId,
       _now = now ?? DateTime.now {
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
  }

  /// Creates a store and runs [init].
  static Future<SqliteSyncStore> open({
    required String dbPath,
    required String deviceId,
    DateTime Function()? now,
  }) async {
    final store = SqliteSyncStore(dbPath: dbPath, deviceId: deviceId, now: now);
    await store.init();
    return store;
  }

  final String _dbPath;
  final String _deviceId;
  final DateTime Function() _now;

  Database? _db;

  @override
  String get deviceId => _deviceId;

  @override
  HlcClock get clock => _readClock(_database);

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('SqliteSyncStore has not been initialized');
    }
    return db;
  }

  @override
  Future<void> init() async {
    if (_db != null) return;
    if (_dbPath != ':memory:' && _dbPath.isNotEmpty) {
      final parent = File(_dbPath).parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
    }
    final db = sqlite3.open(_dbPath);
    try {
      // Same conventions as lib/foundation/sqlite_connection.dart.
      db.execute('PRAGMA journal_mode = DELETE;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('PRAGMA busy_timeout = 5000;');
      _initializeSchema(db);
    } catch (_) {
      db.dispose();
      rethrow;
    }
    _db = db;
  }

  @override
  Future<void> close() async {
    final db = _db;
    if (db == null) return;
    _db = null;
    db.dispose();
  }

  // ---------------------------------------------------------------------------
  // Emit
  // ---------------------------------------------------------------------------

  @override
  Future<SyncOp> emit({
    required String domain,
    required SyncKey key,
    String field = '',
    required SyncOpKind kind,
    Map<String, Object?>? data,
  }) async {
    if (kind == SyncOpKind.clear) {
      throw ArgumentError.value(kind, 'kind', 'Use emitClear for clear ops');
    }
    _checkDomain(domain);
    _checkField(field);
    final keyEncoded = key.encode();
    final payload = data == null ? null : jsonEncode(data);
    final outboxPayload = kind == SyncOpKind.del ? null : payload;

    return _writeTxn((db) {
      // HLC and seq allocation happen inside the same write transaction as the
      // record update and outbox write (protocol §5.3).
      final clock = _refreshClock(db);
      final hlc = clock.tick();
      _persistClock(db, clock);

      // Only rows beyond the frozen watermark may be rewritten in place: a
      // frozen row may already be part of an in-flight upload.
      final pending = _findPendingOutbox(
        db,
        domain,
        keyEncoded,
        field,
        frozenUpTo: _readFrozenUpTo(db),
      );
      final seq = pending?.seq ?? _allocateSeq(db);
      final version = Version(hlc, seq);

      final current = _readRecord(db, domain, keyEncoded, field);
      if (kind == SyncOpKind.del) {
        final deletedVersion = maxVersion(current?.deletedVersion, version)!;
        _writeRecord(
          db,
          domain: domain,
          keyEncoded: keyEncoded,
          field: field,
          version: current?.version ?? version,
          deletedVersion: deletedVersion,
          dataJson: current?.dataJson,
        );
      } else {
        _writeRecord(
          db,
          domain: domain,
          keyEncoded: keyEncoded,
          field: field,
          version: version,
          // Upserting a value newer than a tombstone makes it visible; keeping
          // the old tombstone is harmless and preserves the "latest remove"
          // version for LWW comparisons.
          deletedVersion: current?.deletedVersion,
          dataJson: payload,
        );
      }

      if (pending != null) {
        db.execute(
          'UPDATE sync_outbox SET hlc = ?, op = ?, payload = ? WHERE seq = ?',
          [hlc.encoded, kind.name, outboxPayload, seq],
        );
      } else {
        db.execute(
          'INSERT INTO sync_outbox (seq, hlc, d, k, f, op, payload) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            seq,
            hlc.encoded,
            domain,
            keyEncoded,
            field,
            kind.name,
            outboxPayload,
          ],
        );
      }

      return SyncOp(
        deviceId: _deviceId,
        seq: seq,
        version: version,
        domain: domain,
        key: key,
        field: field,
        kind: kind,
        data: kind == SyncOpKind.del ? null : data,
      );
    });
  }

  @override
  Future<SyncOp> emitClear(String domain) async {
    _checkDomain(domain);
    return _writeTxn((db) {
      final clock = _refreshClock(db);
      final hlc = clock.tick();
      _persistClock(db, clock);

      final pending = _findPendingOutbox(
        db,
        domain,
        _clearKey,
        '',
        frozenUpTo: _readFrozenUpTo(db),
      );
      final seq = pending?.seq ?? _allocateSeq(db);
      final version = Version(hlc, seq);

      final currentCutoff = _readCutoff(db, domain);
      if (currentCutoff == null || version > currentCutoff) {
        _writeCutoff(db, domain, version);
      }

      if (pending != null) {
        db.execute(
          'UPDATE sync_outbox SET hlc = ?, op = ?, payload = NULL '
          'WHERE seq = ?',
          [hlc.encoded, SyncOpKind.clear.name, seq],
        );
      } else {
        db.execute(
          'INSERT INTO sync_outbox (seq, hlc, d, k, f, op, payload) '
          'VALUES (?, ?, ?, ?, ?, ?, NULL)',
          [seq, hlc.encoded, domain, _clearKey, '', SyncOpKind.clear.name],
        );
      }

      return SyncOp(
        deviceId: _deviceId,
        seq: seq,
        version: version,
        domain: domain,
        field: '',
        kind: SyncOpKind.clear,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Outbox / push
  // ---------------------------------------------------------------------------

  @override
  Future<List<SyncOp>> pendingOps({
    int limit = 2000,
    int maxBytes = 1 << 20,
  }) async {
    if (limit <= 0) return const [];
    // Persisting the frozen watermark must be atomic with reading the rows, so
    // the batch that is handed out is exactly the range that is frozen.
    return _writeTxn((db) {
      final rows = db.select('SELECT * FROM sync_outbox ORDER BY seq ASC');
      final ops = <SyncOp>[];
      var bytes = 0;
      int? expectedSeq;
      for (final row in rows) {
        if (ops.length >= limit) break;
        final seq = row['seq'] as int;
        // Defensive: never hand out a non-contiguous batch (receivers advance
        // by a contiguous watermark).
        expectedSeq ??= seq;
        if (seq != expectedSeq) break;
        final op = _opFromOutboxRow(row);
        final size = utf8.encode(jsonEncode(op.toJson())).length + 1;
        // Always return at least one op so the engine can make progress even
        // if a single op exceeds maxBytes (a lone op is bounded by the wire
        // format).
        if (ops.isNotEmpty && bytes + size > maxBytes) break;
        ops.add(op);
        bytes += size;
        expectedSeq = seq + 1;
      }

      final frozenUpTo = _readFrozenUpTo(db);
      if (ops.isEmpty) {
        // Nothing is pending: no row can be in flight, drop a stale marker.
        if (rows.isEmpty && frozenUpTo != 0) {
          _writeFrozenUpTo(db, 0);
        }
      } else if (ops.last.seq > frozenUpTo) {
        // Freeze the whole contiguous prefix returned to the caller. Existing
        // frozen rows are kept frozen even when this call returns less than a
        // previous call (e.g. a small limit).
        _writeFrozenUpTo(db, ops.last.seq);
      }
      return ops;
    });
  }

  @override
  Future<int> pendingCount() async {
    return _selectInt(_database, 'SELECT COUNT(*) AS v FROM sync_outbox');
  }

  @override
  Future<int> getNextSeq() async {
    return _readMetaInt(_database, _metaNextSeq) ?? 0;
  }

  @override
  Future<int> getLastPush() async {
    return _readMetaInt(_database, _metaLastPush) ?? 0;
  }

  @override
  Future<void> markPushed(int upToSeq) async {
    if (upToSeq < 0) {
      throw ArgumentError.value(upToSeq, 'upToSeq', 'Must be >= 0');
    }
    _writeTxn((db) {
      final frozenUpTo = _readFrozenUpTo(db);
      db.execute('DELETE FROM sync_outbox WHERE seq <= ?', [upToSeq]);
      // Recompute the freeze for the rows that survived the ack: rows that
      // were frozen and are still pending stay frozen; if none remain, the
      // marker is cleared so coalescing can resume.
      final maxRemaining = _selectInt(
        db,
        'SELECT COALESCE(MAX(seq), 0) AS v FROM sync_outbox',
      );
      var newFrozenUpTo = 0;
      if (frozenUpTo > upToSeq && maxRemaining > upToSeq) {
        newFrozenUpTo = frozenUpTo < maxRemaining ? frozenUpTo : maxRemaining;
      }
      _writeFrozenUpTo(db, newFrozenUpTo);
      final lastPush = _readMetaInt(db, _metaLastPush) ?? 0;
      if (upToSeq > lastPush) {
        _writeMetaInt(db, _metaLastPush, upToSeq);
      }
      // Snapshot compaction may advance lastPush past nextSeq; keep allocating
      // from a value that is strictly greater than everything already pushed.
      final nextSeq = _readMetaInt(db, _metaNextSeq) ?? 0;
      final floor = upToSeq > lastPush ? upToSeq : lastPush;
      if (floor > nextSeq) {
        _writeMetaInt(db, _metaNextSeq, floor);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Merge
  // ---------------------------------------------------------------------------

  @override
  Future<SyncApplyStats> applyOps(Iterable<SyncOp> ops) async {
    final batch = List<SyncOp>.of(ops);
    if (batch.isEmpty) return const SyncApplyStats();
    return _writeTxn((db) {
      _setApplyingRemote(db, true);
      try {
        final clock = _refreshClock(db);
        final cutoffs = _loadCutoffs(db);
        var applied = 0;
        var stale = 0;
        var skipped = 0;
        var duplicates = 0;

        for (final op in batch) {
          clock.observe(op.version.hlc);
          if (op.isClear) {
            final existing = cutoffs[op.domain];
            if (existing == null || op.version > existing) {
              cutoffs[op.domain] = op.version;
              _writeCutoff(db, op.domain, op.version);
              applied++;
            } else if (op.version == existing) {
              duplicates++;
            } else {
              stale++;
            }
            continue;
          }
          final cutoff = cutoffs[op.domain];
          if (cutoff != null && op.version < cutoff) {
            skipped++;
            continue;
          }
          switch (_applyOp(db, op)) {
            case _Outcome.applied:
              applied++;
            case _Outcome.stale:
              stale++;
              _logConflict(db, op, cutoffs[op.domain]);
            case _Outcome.duplicate:
              duplicates++;
          }
        }

        _persistClock(db, clock);
        return SyncApplyStats(
          applied: applied,
          stale: stale,
          skippedByCutoff: skipped,
          duplicates: duplicates,
        );
      } finally {
        _setApplyingRemote(db, false);
      }
    });
  }

  @override
  Future<SyncApplyStats> applySnapshot(
    ParsedSnapshot snapshot, {
    required Set<String> enabledDomains,
  }) async {
    return _writeTxn((db) {
      _setApplyingRemote(db, true);
      try {
        final clock = _refreshClock(db);
        // Observing the snapshot meta HLC guarantees the next local emit is
        // greater than everything the snapshot covered.
        clock.observe(snapshot.info.hlc);
        final cutoffs = _loadCutoffs(db);

        var applied = 0;
        var stale = 0;
        var skipped = 0;
        var duplicates = 0;

        // Clears first, so records carried by the same snapshot can be filtered
        // by the final cutoff. Only enabled domains are applied.
        for (final entry in snapshot.clears.entries) {
          clock.observe(entry.value.hlc);
          if (!enabledDomains.contains(entry.key)) continue;
          final existing = cutoffs[entry.key];
          if (existing == null || entry.value > existing) {
            cutoffs[entry.key] = entry.value;
            _writeCutoff(db, entry.key, entry.value);
            applied++;
          } else if (entry.value == existing) {
            duplicates++;
          } else {
            stale++;
          }
        }

        for (final record in snapshot.records) {
          clock.observe(record.version.hlc);
          final deleted = record.deletedVersion;
          if (deleted != null) clock.observe(deleted.hlc);
          if (!enabledDomains.contains(record.domain)) continue;
          final cutoff = cutoffs[record.domain];
          if (cutoff != null && record.version < cutoff) {
            skipped++;
            continue;
          }
          switch (_applySnapshotRecord(db, record)) {
            case _Outcome.applied:
              applied++;
            case _Outcome.stale:
              stale++;
            case _Outcome.duplicate:
              duplicates++;
          }
        }

        // Watermarks are delivery facts, not data: merge them with max
        // semantics regardless of domain filtering and never let them regress.
        for (final entry in snapshot.info.applied.entries) {
          _mergeApplied(db, entry.key, entry.value);
        }

        _persistClock(db, clock);
        return SyncApplyStats(
          applied: applied,
          stale: stale,
          skippedByCutoff: skipped,
          duplicates: duplicates,
        );
      } finally {
        _setApplyingRemote(db, false);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Snapshot dump
  // ---------------------------------------------------------------------------

  @override
  Future<Iterable<StoredRecord>> dumpRecords({Set<String>? domains}) async {
    final db = _database;
    final cutoffs = _loadCutoffs(db);
    final records = <StoredRecord>[];
    for (final row in db.select(
      'SELECT d, k, f, hlc, seq, deletedHlc, deletedSeq, data FROM sync_reg',
    )) {
      final domain = row['d'] as String;
      if (domains != null && !domains.contains(domain)) continue;
      final version = Version(
        Hlc.parse(row['hlc'] as String),
        row['seq'] as int,
      );
      // Records older than the domain cutoff are not part of the current state
      // and are already implied by the snapshot's clear line.
      final cutoff = cutoffs[domain];
      if (cutoff != null && version < cutoff) continue;
      records.add(
        StoredRecord(
          domain: domain,
          key: SyncKey.decode(row['k'] as String),
          field: row['f'] as String,
          version: version,
          deletedVersion: _rowVersion(row['deletedHlc'], row['deletedSeq']),
          data: _decodeData(row['data'] as String?),
        ),
      );
    }
    records.sort((a, b) {
      var comparison = a.domain.compareTo(b.domain);
      if (comparison != 0) return comparison;
      comparison = a.key.compareTo(b.key);
      if (comparison != 0) return comparison;
      return a.field.compareTo(b.field);
    });
    return records;
  }

  @override
  Future<Iterable<StoredClear>> dumpClears({Set<String>? domains}) async {
    final db = _database;
    final clears = <StoredClear>[];
    for (final row in db.select(
      'SELECT d, cutoffHlc, cutoffSeq FROM sync_clear',
    )) {
      final domain = row['d'] as String;
      if (domains != null && !domains.contains(domain)) continue;
      clears.add(
        StoredClear(
          domain: domain,
          cutoff: Version(
            Hlc.parse(row['cutoffHlc'] as String),
            row['cutoffSeq'] as int,
          ),
        ),
      );
    }
    clears.sort((a, b) => a.domain.compareTo(b.domain));
    return clears;
  }

  // ---------------------------------------------------------------------------
  // Watermarks / snapshot meta
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, int>> getApplied() async {
    final applied = <String, int>{};
    for (final row in _database.select(
      'SELECT device, seq FROM sync_applied',
    )) {
      applied[row['device'] as String] = row['seq'] as int;
    }
    return applied;
  }

  @override
  Future<int> getAppliedSeq(String deviceId) async {
    return _readApplied(_database, deviceId) ?? 0;
  }

  @override
  Future<void> setApplied(String deviceId, int seq) async {
    if (seq < 0) {
      throw ArgumentError.value(seq, 'seq', 'Must be >= 0');
    }
    _writeTxn((db) => _mergeApplied(db, deviceId, seq));
  }

  @override
  Future<SnapshotInfo?> getLastSnapshot() async {
    final raw = _readMeta(_database, _metaLastSnapshot);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SnapshotInfo.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> setLastSnapshot(SnapshotInfo info) async {
    _writeTxn((db) {
      _writeMeta(db, _metaLastSnapshot, jsonEncode(info.toJson()));
    });
  }

  @override
  Future<String?> getMeta(String key) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key', 'Must not be empty');
    return _readMeta(_database, key);
  }

  @override
  Future<void> setMeta(String key, String? value) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key', 'Must not be empty');
    _writeTxn((db) {
      if (value == null) {
        db.execute('DELETE FROM sync_meta WHERE key = ?', [key]);
      } else {
        _writeMeta(db, key, value);
      }
    });
  }

  @override
  Future<Hlc> tickHlcForMeta() async {
    return _writeTxn((db) {
      final clock = _refreshClock(db);
      final hlc = clock.tick();
      _persistClock(db, clock);
      return hlc;
    });
  }

  @override
  Future<Version?> versionOf(String domain, SyncKey key, String field) async {
    final record = _readRecord(_database, domain, key.encode(), field);
    return record?.version;
  }

  @override
  Future<StoredRecord?> recordOf(
    String domain,
    SyncKey key,
    String field,
  ) async {
    final keyEncoded = key.encode();
    final record = _readRecord(_database, domain, keyEncoded, field);
    if (record == null) return null;
    return StoredRecord(
      domain: domain,
      key: key,
      field: field,
      version: record.version,
      deletedVersion: record.deletedVersion,
      data: _decodeData(record.dataJson),
    );
  }

  @override
  Future<List<Map<String, Object?>>> getRecentConflicts({
    int limit = 50,
  }) async {
    if (limit <= 0) return const [];
    final rows = _database.select(
      'SELECT d, k, f, localHlc, remoteHlc, at FROM sync_conflict_log '
      'ORDER BY id DESC LIMIT ?',
      [limit],
    );
    return [
      for (final row in rows)
        {
          'domain': row['d'],
          'key': row['k'],
          'field': row['f'],
          'localHlc': row['localHlc'],
          'remoteHlc': row['remoteHlc'],
          'at': row['at'],
        },
    ];
  }

  @override
  Future<void> clearConflicts() async {
    _writeTxn((db) => db.execute('DELETE FROM sync_conflict_log'));
  }

  void _logConflict(Database db, SyncOp op, Version? cutoff) {
    String? localHlc;
    if (!op.isClear) {
      final current = _readRecord(db, op.domain, op.key!.encode(), op.field);
      localHlc = current?.version.hlc.encoded;
    } else {
      localHlc = cutoff?.hlc.encoded;
    }
    db.execute(
      'INSERT INTO sync_conflict_log (d, k, f, localHlc, remoteHlc, at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        op.domain,
        op.isClear ? '*' : op.key!.encode(),
        op.field,
        localHlc,
        op.version.hlc.encoded,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Transaction / schema plumbing
  // ---------------------------------------------------------------------------

  T _writeTxn<T>(T Function(Database db) body) {
    final db = _database;
    db.execute('BEGIN IMMEDIATE;');
    try {
      final result = body(db);
      db.execute('COMMIT;');
      return result;
    } catch (_) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {
        // Ignore rollback failures: the original error is more useful.
      }
      rethrow;
    }
  }

  void _initializeSchema(Database db) {
    db.execute('BEGIN IMMEDIATE;');
    try {
      for (final statement in _schemaStatements) {
        db.execute(statement);
      }
      final storedDeviceId = _readMeta(db, _metaDeviceId);
      if (storedDeviceId == null) {
        _writeMeta(db, _metaDeviceId, _deviceId);
        _writeMetaInt(db, _metaHlcMs, 0);
        _writeMetaInt(db, _metaHlcCounter, 0);
        _writeMetaInt(db, _metaNextSeq, 0);
        _writeMetaInt(db, _metaLastPush, 0);
        _writeMetaInt(db, _metaFrozenUpTo, 0);
      } else if (storedDeviceId != _deviceId) {
        throw StateError(
          'Sync database belongs to device $storedDeviceId, '
          'not $_deviceId',
        );
      }

      // Repair counters so a lossy upgrade can never reuse a seq or allocate an
      // HLC smaller than one that is already persisted.
      final nextSeq = _readMetaInt(db, _metaNextSeq) ?? 0;
      final lastPush = _readMetaInt(db, _metaLastPush) ?? 0;
      final frozenUpTo = _readFrozenUpTo(db);
      final maxOutboxSeq = _selectInt(
        db,
        'SELECT COALESCE(MAX(seq), 0) AS v FROM sync_outbox',
      );
      var floor = lastPush;
      if (maxOutboxSeq > floor) floor = maxOutboxSeq;
      if (frozenUpTo > floor) floor = frozenUpTo;
      if (floor > nextSeq) {
        _writeMetaInt(db, _metaNextSeq, floor);
      }

      db.execute('COMMIT;');
    } catch (_) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {
        // Ignore.
      }
      rethrow;
    }
  }

  void _setApplyingRemote(Database db, bool value) {
    db.execute(
      'INSERT OR REPLACE INTO sync_txn_flag (key, value) VALUES (?, ?)',
      ['applyingRemote', value ? '1' : ''],
    );
  }

  // ---------------------------------------------------------------------------
  // Meta helpers
  // ---------------------------------------------------------------------------

  String? _readMeta(Database db, String key) {
    for (final row in db.select('SELECT value FROM sync_meta WHERE key = ?', [
      key,
    ])) {
      return row['value'] as String?;
    }
    return null;
  }

  int? _readMetaInt(Database db, String key) {
    final raw = _readMeta(db, key);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  void _writeMeta(Database db, String key, String value) {
    db.execute('INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)', [
      key,
      value,
    ]);
  }

  void _writeMetaInt(Database db, String key, int value) {
    _writeMeta(db, key, '$value');
  }

  HlcClock _readClock(Database db) {
    return HlcClock(
      deviceId: _deviceId,
      now: _now,
      ms: _readMetaInt(db, _metaHlcMs) ?? 0,
      counter: _readMetaInt(db, _metaHlcCounter) ?? 0,
    );
  }

  /// Re-reads the persisted HLC right before allocating. This is what makes
  /// several connections on the same file safe: the read happens while holding
  /// the `BEGIN IMMEDIATE` write lock.
  HlcClock _refreshClock(Database db) => _readClock(db);

  void _persistClock(Database db, HlcClock clock) {
    _writeMetaInt(db, _metaHlcMs, clock.ms);
    _writeMetaInt(db, _metaHlcCounter, clock.counter);
  }

  /// Highest outbox seq that [pendingOps] handed out and that must not be
  /// rewritten in place until [markPushed] acknowledges it.
  int _readFrozenUpTo(Database db) {
    return _readMetaInt(db, _metaFrozenUpTo) ?? 0;
  }

  void _writeFrozenUpTo(Database db, int seq) {
    _writeMetaInt(db, _metaFrozenUpTo, seq);
  }

  int _allocateSeq(Database db) {
    final seq = (_readMetaInt(db, _metaNextSeq) ?? 0) + 1;
    _writeMetaInt(db, _metaNextSeq, seq);
    return seq;
  }

  int _selectInt(Database db, String sql, [List<Object?> params = const []]) {
    for (final row in db.select(sql, params)) {
      final value = row['v'];
      return value is int ? value : 0;
    }
    return 0;
  }

  // ---------------------------------------------------------------------------
  // Outbox helpers
  // ---------------------------------------------------------------------------

  /// Newest pending outbox row for `(d, k, f)` that may still be rewritten.
  ///
  /// Rows with `seq <= frozenUpTo` may be part of an in-flight upload and are
  /// never overwritten; when only frozen rows exist this returns `null` so the
  /// caller allocates a fresh seq and appends a new row.
  _OutboxRow? _findPendingOutbox(
    Database db,
    String domain,
    String keyEncoded,
    String field, {
    required int frozenUpTo,
  }) {
    for (final row in db.select(
      'SELECT seq, hlc FROM sync_outbox '
      'WHERE d = ? AND k = ? AND f = ? AND seq > ? '
      'ORDER BY seq DESC LIMIT 1',
      [domain, keyEncoded, field, frozenUpTo],
    )) {
      return _OutboxRow(seq: row['seq'] as int, hlc: row['hlc'] as String);
    }
    return null;
  }

  SyncOp _opFromOutboxRow(Row row) {
    final seq = row['seq'] as int;
    final kind = SyncOpKind.parse(row['op'] as String);
    final hlc = Hlc.parse(row['hlc'] as String);
    final domain = row['d'] as String;
    final field = row['f'] as String;
    return SyncOp(
      deviceId: _deviceId,
      seq: seq,
      version: Version(hlc, seq),
      domain: domain,
      key: kind == SyncOpKind.clear ? null : SyncKey.decode(row['k'] as String),
      field: field,
      kind: kind,
      data: _decodeData(row['payload'] as String?),
    );
  }

  // ---------------------------------------------------------------------------
  // Record helpers
  // ---------------------------------------------------------------------------

  _DbRecord? _readRecord(
    Database db,
    String domain,
    String keyEncoded,
    String field,
  ) {
    for (final row in db.select(
      'SELECT hlc, seq, deletedHlc, deletedSeq, data FROM sync_reg '
      'WHERE d = ? AND k = ? AND f = ?',
      [domain, keyEncoded, field],
    )) {
      return _DbRecord(
        version: Version(Hlc.parse(row['hlc'] as String), row['seq'] as int),
        deletedVersion: _rowVersion(row['deletedHlc'], row['deletedSeq']),
        dataJson: row['data'] as String?,
      );
    }
    return null;
  }

  void _writeRecord(
    Database db, {
    required String domain,
    required String keyEncoded,
    required String field,
    required Version version,
    required Version? deletedVersion,
    required String? dataJson,
  }) {
    db.execute(
      'INSERT INTO sync_reg (d, k, f, hlc, seq, deletedHlc, deletedSeq, data) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(d, k, f) DO UPDATE SET '
      'hlc = excluded.hlc, seq = excluded.seq, '
      'deletedHlc = excluded.deletedHlc, deletedSeq = excluded.deletedSeq, '
      'data = excluded.data',
      [
        domain,
        keyEncoded,
        field,
        version.hlc.encoded,
        version.seq,
        deletedVersion?.hlc.encoded,
        deletedVersion?.seq,
        _normalizeData(version, deletedVersion, dataJson),
      ],
    );
  }

  /// A live record must carry a non-null payload ([StoredRecord.visible] is
  /// `data != null` when there is no tombstone); a hidden record is stored as a
  /// payload-less tombstone.
  String? _normalizeData(
    Version version,
    Version? deletedVersion,
    String? dataJson,
  ) {
    if (deletedVersion != null && version.compareTo(deletedVersion) <= 0) {
      return null;
    }
    return dataJson ?? '{}';
  }

  Version? _rowVersion(Object? deletedHlc, Object? deletedSeq) {
    if (deletedHlc is! String || deletedSeq is! int) return null;
    return Version(Hlc.parse(deletedHlc), deletedSeq);
  }

  Map<String, Object?>? _decodeData(String? text) {
    if (text == null) return null;
    final decoded = jsonDecode(text);
    if (decoded is Map) return decoded.cast<String, Object?>();
    return null;
  }

  // ---------------------------------------------------------------------------
  // Clear cutoff helpers
  // ---------------------------------------------------------------------------

  Version? _readCutoff(Database db, String domain) {
    for (final row in db.select(
      'SELECT cutoffHlc, cutoffSeq FROM sync_clear WHERE d = ?',
      [domain],
    )) {
      return Version(
        Hlc.parse(row['cutoffHlc'] as String),
        row['cutoffSeq'] as int,
      );
    }
    return null;
  }

  Map<String, Version> _loadCutoffs(Database db) {
    final cutoffs = <String, Version>{};
    for (final row in db.select(
      'SELECT d, cutoffHlc, cutoffSeq FROM sync_clear',
    )) {
      cutoffs[row['d'] as String] = Version(
        Hlc.parse(row['cutoffHlc'] as String),
        row['cutoffSeq'] as int,
      );
    }
    return cutoffs;
  }

  void _writeCutoff(Database db, String domain, Version cutoff) {
    db.execute(
      'INSERT INTO sync_clear (d, cutoffHlc, cutoffSeq) VALUES (?, ?, ?) '
      'ON CONFLICT(d) DO UPDATE SET '
      'cutoffHlc = excluded.cutoffHlc, cutoffSeq = excluded.cutoffSeq',
      [domain, cutoff.hlc.encoded, cutoff.seq],
    );
  }

  // ---------------------------------------------------------------------------
  // Applied watermark helpers
  // ---------------------------------------------------------------------------

  int? _readApplied(Database db, String deviceId) {
    for (final row in db.select(
      'SELECT seq FROM sync_applied WHERE device = ?',
      [deviceId],
    )) {
      return row['seq'] as int;
    }
    return null;
  }

  void _mergeApplied(Database db, String deviceId, int seq) {
    final current = _readApplied(db, deviceId) ?? 0;
    if (seq <= current) return;
    db.execute(
      'INSERT INTO sync_applied (device, seq) VALUES (?, ?) '
      'ON CONFLICT(device) DO UPDATE SET seq = excluded.seq',
      [deviceId, seq],
    );
  }

  // ---------------------------------------------------------------------------
  // Merge helpers
  // ---------------------------------------------------------------------------

  _Outcome _applyOp(Database db, SyncOp op) {
    final keyEncoded = op.key!.encode();
    final current = _readRecord(db, op.domain, keyEncoded, op.field);
    switch (op.kind) {
      case SyncOpKind.upsert:
      case SyncOpKind.add:
        if (current == null) {
          _writeRecord(
            db,
            domain: op.domain,
            keyEncoded: keyEncoded,
            field: op.field,
            version: op.version,
            deletedVersion: null,
            dataJson: op.data == null ? null : jsonEncode(op.data),
          );
          return _Outcome.applied;
        }
        final comparison = op.version.compareTo(current.version);
        if (comparison > 0) {
          _writeRecord(
            db,
            domain: op.domain,
            keyEncoded: keyEncoded,
            field: op.field,
            version: op.version,
            deletedVersion: current.deletedVersion,
            dataJson: op.data == null ? null : jsonEncode(op.data),
          );
          return _Outcome.applied;
        }
        return comparison == 0 ? _Outcome.duplicate : _Outcome.stale;
      case SyncOpKind.del:
        if (current == null) {
          _writeRecord(
            db,
            domain: op.domain,
            keyEncoded: keyEncoded,
            field: op.field,
            version: op.version,
            deletedVersion: op.version,
            dataJson: null,
          );
          return _Outcome.applied;
        }
        final deleted = current.deletedVersion;
        if (deleted != null) {
          final comparison = op.version.compareTo(deleted);
          if (comparison < 0) return _Outcome.stale;
          if (comparison == 0) return _Outcome.duplicate;
        }
        _writeRecord(
          db,
          domain: op.domain,
          keyEncoded: keyEncoded,
          field: op.field,
          version: current.version,
          deletedVersion: op.version,
          dataJson: current.dataJson,
        );
        return _Outcome.applied;
      case SyncOpKind.clear:
        throw StateError('Clear ops must be applied by applyClear path');
    }
  }

  _Outcome _applySnapshotRecord(Database db, SnapshotRecord record) {
    final keyEncoded = record.key.encode();
    final current = _readRecord(db, record.domain, keyEncoded, record.field);
    final recordDataJson = record.data == null ? null : jsonEncode(record.data);

    if (current == null) {
      _writeRecord(
        db,
        domain: record.domain,
        keyEncoded: keyEncoded,
        field: record.field,
        version: record.version,
        deletedVersion: record.deletedVersion,
        dataJson: recordDataJson,
      );
      return _Outcome.applied;
    }

    final versionComparison = record.version.compareTo(current.version);
    final mergedVersion = versionComparison > 0
        ? record.version
        : current.version;
    final mergedDeleted = maxVersion(
      current.deletedVersion,
      record.deletedVersion,
    );
    final String? mergedDataJson;
    if (versionComparison > 0) {
      mergedDataJson = recordDataJson;
    } else if (versionComparison == 0) {
      mergedDataJson = current.dataJson ?? recordDataJson;
    } else {
      mergedDataJson = current.dataJson;
    }
    final normalized = _normalizeData(
      mergedVersion,
      mergedDeleted,
      mergedDataJson,
    );
    final deletedChanged = !_versionEquals(
      current.deletedVersion,
      mergedDeleted,
    );
    final changed =
        versionComparison > 0 ||
        deletedChanged ||
        normalized != current.dataJson;
    if (!changed) {
      if (versionComparison == 0 && !deletedChanged) {
        return _Outcome.duplicate;
      }
      return _Outcome.stale;
    }
    _writeRecord(
      db,
      domain: record.domain,
      keyEncoded: keyEncoded,
      field: record.field,
      version: mergedVersion,
      deletedVersion: mergedDeleted,
      dataJson: mergedDataJson,
    );
    return _Outcome.applied;
  }

  bool _versionEquals(Version? a, Version? b) {
    if (a == null || b == null) return a == null && b == null;
    return a == b;
  }

  void _checkDomain(String domain) {
    if (!syncDomainRegExp.hasMatch(domain)) {
      throw ArgumentError.value(domain, 'domain', 'Invalid sync domain');
    }
  }

  void _checkField(String field) {
    if (!syncFieldRegExp.hasMatch(field)) {
      throw ArgumentError.value(field, 'field', 'Invalid sync field group');
    }
  }
}
