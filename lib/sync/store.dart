/// Local state store contract used by the sync engine.
///
/// The store owns:
///  - the local device id and persisted HLC / outbox seq,
///  - the pending outbox (with in-place coalescing but contiguous seqs),
///  - merged records + tombstones + clear cutoffs,
///  - per-device applied watermarks,
///  - the last uploaded snapshot info.
///
/// Implementations must make "apply a batch of ops" atomic and must allocate
/// HLC/seq inside the same SQLite write transaction as the business write
/// (protocol doc §5.3).
library;

import 'hlc.dart';
import 'key_codec.dart';
import 'op.dart';
import 'snapshot.dart';
import 'version.dart';

class SyncApplyStats {
  const SyncApplyStats({
    this.applied = 0,
    this.stale = 0,
    this.skippedByCutoff = 0,
    this.duplicates = 0,
  });

  /// Ops that moved a local version forward.
  final int applied;

  /// Ops ignored because they are older than the local version.
  final int stale;

  /// Ops ignored because they are older than the domain cutoff.
  final int skippedByCutoff;

  /// Ops identical to the already-known version.
  final int duplicates;

  int get total => applied + stale + skippedByCutoff + duplicates;

  bool get changed => applied > 0;

  SyncApplyStats operator +(SyncApplyStats other) => SyncApplyStats(
    applied: applied + other.applied,
    stale: stale + other.stale,
    skippedByCutoff: skippedByCutoff + other.skippedByCutoff,
    duplicates: duplicates + other.duplicates,
  );

  @override
  String toString() =>
      'SyncApplyStats(applied=$applied stale=$stale '
      'cutoff=$skippedByCutoff dup=$duplicates)';
}

/// A merged record (register value, set element or tombstone).
class StoredRecord {
  const StoredRecord({
    required this.domain,
    required this.key,
    required this.field,
    required this.version,
    this.deletedVersion,
    this.data,
  });

  final String domain;
  final SyncKey key;
  final String field;
  final Version version;
  final Version? deletedVersion;
  final Map<String, Object?>? data;

  bool get visible =>
      deletedVersion == null ? data != null : version > deletedVersion!;

  @override
  String toString() =>
      'StoredRecord($domain/$key/$field version=$version '
      'deleted=$deletedVersion visible=$visible)';
}

class StoredClear {
  const StoredClear({required this.domain, required this.cutoff});

  final String domain;
  final Version cutoff;

  @override
  String toString() => 'StoredClear($domain @$cutoff)';
}

abstract class SyncStore {
  /// Stable id of this installation/device.
  String get deviceId;

  /// Persisted HLC generator; only valid after [init].
  HlcClock get clock;

  Future<void> init();

  Future<void> close();

  /// Emits a local upsert/add/del for `(domain, key, field)`.
  ///
  /// Must allocate HLC + seq, update the local merged record and enqueue the
  /// op in the outbox atomically. Pending ops for the same `(d, k, f)` may be
  /// coalesced in place (same seq).
  Future<SyncOp> emit({
    required String domain,
    required SyncKey key,
    String field = '',
    required SyncOpKind kind,
    Map<String, Object?>? data,
  });

  /// Emits a domain-wide cutoff clear.
  Future<SyncOp> emitClear(String domain);

  /// Returns pending ops in ascending seq order, respecting limits.
  ///
  /// Implementations must "freeze" the returned contiguous prefix: subsequent
  /// [emit] calls for the same `(domain, key, field)` must allocate a new seq
  /// instead of rewriting a frozen row in place, and the frozen marker must
  /// survive a restart. This prevents mutating a batch while it is being
  /// uploaded (see protocol doc §7.2) which would otherwise make a retry
  /// upload different content under an already-acknowledged seq.
  Future<List<SyncOp>> pendingOps({int limit = 2000, int maxBytes = 1 << 20});

  Future<int> pendingCount();

  /// Highest seq ever allocated (used for snapshot compaction watermarks).
  Future<int> getNextSeq();

  /// Highest seq that has been successfully uploaded.
  Future<int> getLastPush();

  /// Deletes outbox rows with `seq <= upToSeq` and advances [getLastPush].
  ///
  /// Must also clear/recompute the frozen marker for the deleted range so
  /// later emits can coalesce into remaining pending rows again.
  Future<void> markPushed(int upToSeq);

  /// Applies remote ops (or locally replayed ops) in one transaction.
  ///
  /// Must observe remote HLCs and honour clear cutoffs. Domain filtering and
  /// watermark advancement are the engine's responsibility.
  Future<SyncApplyStats> applyOps(Iterable<SyncOp> ops);

  /// Snapshot generation source: every merged record including tombstones.
  Future<Iterable<StoredRecord>> dumpRecords({Set<String>? domains});

  /// Snapshot generation source: domain clear cutoffs.
  Future<Iterable<StoredClear>> dumpClears({Set<String>? domains});

  /// Applies a parsed snapshot atomically.
  ///
  /// Only records/clears of enabled domains are applied. Watermarks from
  /// [ParsedSnapshot.info] are merged with `max` semantics.
  Future<SyncApplyStats> applySnapshot(
    ParsedSnapshot snapshot, {
    required Set<String> enabledDomains,
  });

  /// All applied watermarks (`other device id -> seq`).
  Future<Map<String, int>> getApplied();

  Future<int> getAppliedSeq(String deviceId);

  Future<void> setApplied(String deviceId, int seq);

  /// Last snapshot this device uploaded (tracked for periodic compaction).
  Future<SnapshotInfo?> getLastSnapshot();

  Future<void> setLastSnapshot(SnapshotInfo info);

  /// Generic engine metadata (e.g. a `pendingCompaction` crash-recovery
  /// marker). Keys are engine-owned; implementations persist them in
  /// `sync_meta`. [setMeta] with `null` deletes the key.
  Future<String?> getMeta(String key);

  Future<void> setMeta(String key, String? value);

  /// Ticks the persisted HLC for snapshot metadata (does not emit an op).
  Future<Hlc> tickHlcForMeta();

  Future<Version?> versionOf(String domain, SyncKey key, String field);

  Future<StoredRecord?> recordOf(String domain, SyncKey key, String field);

  /// Recent LWW conflicts observed while applying remote ops (debugging only;
  /// payloads are not stored).
  Future<List<Map<String, Object?>>> getRecentConflicts({int limit = 50});

  Future<void> clearConflicts();
}
