/// High-level orchestration of the Venera v2 sync protocol.
///
/// This file implements the device side of `doc/webdav_sync_v2_protocol.md`
/// §7:
///
///  * [SyncEngine.push]      – upload the pending outbox as change files
///                             (protocol §7.2),
///  * [SyncEngine.pull]      – merge other devices' change files (§7.3),
///  * [SyncEngine.bootstrap] – snapshot based gap repair (§7.4),
///  * [SyncEngine.replayDomain] – rebuild one domain from all retained remote
///                             artifacts, ignoring watermarks (§3.4/§7.4),
///  * [SyncEngine.snapshot]  – build/upload our complete state (§6.2),
///  * [SyncEngine.recoverPendingCompaction] – resume a crashed compaction
///                             snapshot substitution (§7.2 step 7),
///  * [SyncEngine.gc]        – drop our change files covered by a snapshot
///                             (§7.6).
///
/// The engine is pure Dart and talks to the world only through the
/// [SyncStore] and [SyncTransport] contracts, so the whole protocol can be
/// tested without a real WebDAV server or Flutter bindings.
///
/// Design notes:
///
///  * Every public operation is serialized by one internal lock (§7.0); push,
///    pull, snapshot and GC never interleave.
///  * Retries are safe: a change file is only marked pushed after
///    [SyncTransport.writeChanges] succeeded, and the outbox row is only
///    trimmed after the change file is durable. The remote state document is a
///    hint (§2/§7.2 step 5), so a state write failure is reported through
///    [SyncPushResult.stateWritten] instead of failing the push.
///  * Remote input is untrusted: invalid device ids, change files and
///    snapshots are treated as gaps and repaired via a snapshot; records are
///    never partially applied.
///  * Local-only bookkeeping (the last uploaded change seq) is kept in
///    [SyncEngine] memory and rebuilt from [SyncStore.getLastPush] on
///    [init]. It is persisted remotely through `RemoteState.lastChange`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'domains.dart';
import 'hlc.dart';
import 'op.dart';
import 'snapshot.dart';
import 'store.dart';
import 'transport.dart';
import 'version.dart';

/// Human readable protocol version reported by [SyncEngine.status].
const String syncProtocolVersionTag = '2';

/// Result of [SyncEngine.push].
class SyncPushResult {
  const SyncPushResult({
    this.batches = 0,
    this.opsPushed = 0,
    this.lo = 0,
    this.hi = 0,
    this.lastPush = 0,
    this.stateWritten = true,
    this.error,
    this.stateError,
  });

  /// Number of change files written by this call.
  final int batches;

  /// Number of outbox ops covered by the written change files.
  final int opsPushed;

  /// First seq uploaded by this call; `0` when nothing was uploaded.
  final int lo;

  /// Last seq uploaded by this call; `0` when nothing was uploaded.
  final int hi;

  /// [SyncStore.getLastPush] after this call.
  final int lastPush;

  /// Whether the remote state document is known to be current afterwards.
  ///
  /// A state write failure does **not** make the push fail: the change data is
  /// already readable by other devices, only the fast-path hint is stale. A
  /// later [push] retries the state write.
  final bool stateWritten;

  /// Serialization/transport failure while writing change data. When set, the
  /// outbox is left intact so the same `[lo, hi]` range is re-encoded on retry.
  final Object? error;

  /// Failure of the (best effort) remote state write.
  final Object? stateError;

  bool get success => error == null;

  bool get changed => opsPushed > 0;

  @override
  String toString() =>
      'SyncPushResult(batches=$batches ops=$opsPushed range=$lo-$hi '
      'stateWritten=$stateWritten error=$error)';
}

/// One per-device error/warning collected during a sync operation ([SyncEngine.pull],
/// [SyncEngine.bootstrap] repair or [SyncEngine.replayDomain]).
class SyncPullError {
  const SyncPullError({
    required this.deviceId,
    required this.message,
    this.error,
  });

  final String deviceId;
  final String message;
  final Object? error;

  @override
  String toString() => 'SyncPullError($deviceId: $message)';
}

/// Result of [SyncEngine.pull].
class SyncPullResult {
  const SyncPullResult({
    this.devicesInspected = 0,
    this.devicesAdvanced = 0,
    this.rangesRead = 0,
    this.opsRead = 0,
    this.opsApplied = 0,
    this.opsSkipped = 0,
    this.snapshotsApplied = 0,
    this.recordsApplied = 0,
    this.changed = false,
    this.applied = const <String, int>{},
    this.errors = const <SyncPullError>[],
    this.warnings = const <SyncPullError>[],
  });

  /// Non-self devices that were looked at.
  final int devicesInspected;

  /// Devices whose applied watermark was moved forward.
  final int devicesAdvanced;

  /// Change files successfully downloaded and decoded.
  final int rangesRead;

  /// Ops contained in the downloaded change files (before domain filtering).
  final int opsRead;

  /// Ops that advanced a local version (sum of [SyncApplyStats.applied]).
  final int opsApplied;

  /// Ops that were read but deliberately not applied (stale/cutoff/duplicate
  /// or filtered because the domain is disabled/unknown).
  final int opsSkipped;

  /// Snapshots applied while repairing gaps during this pull.
  final int snapshotsApplied;

  /// Records from repaired snapshots that advanced local state.
  final int recordsApplied;

  /// Whether any local record changed.
  final bool changed;

  /// Per-device applied watermarks after the pull.
  final Map<String, int> applied;

  /// Hard failures (a device could not be synchronized).
  final List<SyncPullError> errors;

  /// Tolerated problems (e.g. an unreadable state hint that was recovered
  /// through the directory listing).
  final List<SyncPullError> warnings;

  /// Whether every inspected device was synchronized without hard errors.
  bool get success => errors.isEmpty;

  @override
  String toString() =>
      'SyncPullResult(devices=$devicesInspected advanced=$devicesAdvanced '
      'ranges=$rangesRead ops=$opsRead applied=$opsApplied '
      'skipped=$opsSkipped snapshots=$snapshotsApplied '
      'errors=${errors.length})';
}

/// Result of [SyncEngine.replayDomain].
///
/// The counters distinguish the two data sources a replay may use: change
/// files ([rangesRead]/[opsRead]/[opsApplied]/[opsSkipped]) and, when the
/// change files were pruned by compaction or GC, the device snapshot
/// ([snapshotsRead]/[recordsRead]/[recordsApplied]/[clearsApplied]).
class SyncDomainReplayResult {
  const SyncDomainReplayResult({
    required this.domain,
    this.devicesInspected = 0,
    this.rangesRead = 0,
    this.opsRead = 0,
    this.opsApplied = 0,
    this.opsSkipped = 0,
    this.snapshotsRead = 0,
    this.recordsRead = 0,
    this.recordsApplied = 0,
    this.clearsApplied = 0,
    this.changed = false,
    this.applied = const <String, int>{},
    this.errors = const <SyncPullError>[],
    this.warnings = const <SyncPullError>[],
  });

  /// The replayed domain.
  final String domain;

  /// Non-self devices that were inspected.
  final int devicesInspected;

  /// Change files successfully downloaded and decoded.
  final int rangesRead;

  /// Ops contained in the downloaded change files (before domain filtering).
  final int opsRead;

  /// Ops from change files that advanced a local version.
  final int opsApplied;

  /// Ops that were read but not applied (filtered to another domain, stale,
  /// cutoff or duplicate).
  final int opsSkipped;

  /// Snapshots decoded because the device's change files were pruned/missing.
  final int snapshotsRead;

  /// Snapshot records of the replayed domain that were examined.
  final int recordsRead;

  /// Snapshot records that advanced local state after being converted to ops.
  final int recordsApplied;

  /// Domain clear cutoffs converted to `clear` ops and applied.
  final int clearsApplied;

  /// Whether any local record changed.
  final bool changed;

  /// Applied watermarks after the replay.
  ///
  /// A replay never advances them; the map is exposed so callers can assert the
  /// regular pull state was left untouched.
  final Map<String, int> applied;

  /// Hard failures (a device could not be replayed at all).
  final List<SyncPullError> errors;

  /// Tolerated problems (unreadable/missing device files, corrupt records).
  final List<SyncPullError> warnings;

  bool get success => errors.isEmpty;

  @override
  String toString() =>
      'SyncDomainReplayResult(domain=$domain devices=$devicesInspected '
      'ranges=$rangesRead ops=$opsRead applied=$opsApplied '
      'skipped=$opsSkipped snapshots=$snapshotsRead records=$recordsRead '
      'recordsApplied=$recordsApplied clears=$clearsApplied '
      'changed=$changed warnings=${warnings.length} '
      'errors=${errors.length})';
}

/// Result of [SyncEngine.bootstrap].
class SyncBootstrapResult {
  const SyncBootstrapResult({
    this.deviceId,
    this.candidates = 0,
    this.snapshotsApplied = 0,
    this.recordsConsidered = 0,
    this.recordsApplied = 0,
    this.clearsConsidered = 0,
    this.missingDomains = const <String>{},
    this.error,
    this.pull,
  });

  /// Device that was repaired, or `null` when the best global candidate was
  /// used.
  final String? deviceId;

  /// Number of candidate snapshots discovered.
  final int candidates;

  /// Number of snapshots applied (snapshots are idempotent and may stack).
  final int snapshotsApplied;

  /// Snapshot record lines decoded.
  final int recordsConsidered;

  /// Snapshot records that advanced local state.
  final int recordsApplied;

  /// Snapshot clear cutoff lines decoded.
  final int clearsConsidered;

  /// Enabled domains not covered by any applied snapshot.
  ///
  /// Those domains need a follow-up domain rebuild (§7.4 step 4, §3.4); the
  /// engine does not silently claim they were synchronized.
  final Set<String> missingDomains;

  /// Failure while reading/applying a snapshot. A single corrupt snapshot is
  /// skipped; this is set when no usable snapshot could be applied.
  final Object? error;

  /// Incremental pull run after the snapshots were applied.
  final SyncPullResult? pull;

  bool get success => error == null;

  @override
  String toString() =>
      'SyncBootstrapResult(device=$deviceId candidates=$candidates '
      'snapshots=$snapshotsApplied records=$recordsApplied '
      'missing=$missingDomains error=$error)';
}

/// Result of [SyncEngine.snapshot].
class SyncSnapshotResult {
  const SyncSnapshotResult({
    this.info,
    this.records = 0,
    this.clears = 0,
    this.written = false,
    this.skipped = false,
    this.stateWritten = true,
    this.error,
    this.stateError,
  });

  /// Snapshot metadata (also stored locally via [SyncStore.setLastSnapshot]).
  final SnapshotInfo? info;

  /// Records included in the snapshot (all tombstones included).
  final int records;

  /// Clear cutoffs included in the snapshot.
  final int clears;

  /// Whether the snapshot bytes reached the transport.
  final bool written;

  /// Whether the call was skipped by the periodic policy.
  final bool skipped;

  /// Whether `devices/<self>.json` was updated to point at the snapshot.
  final bool stateWritten;

  /// Snapshot build/upload failure.
  final Object? error;

  /// Remote state write failure (does not invalidate the uploaded snapshot).
  final Object? stateError;

  bool get success => error == null && written;

  @override
  String toString() =>
      'SyncSnapshotResult(info=$info records=$records clears=$clears '
      'written=$written skipped=$skipped stateWritten=$stateWritten '
      'error=$error)';
}

/// Result of [SyncEngine.gc].
class SyncGcResult {
  const SyncGcResult({
    this.deleted = false,
    this.skipped = false,
    this.deletedUpTo = 0,
    this.snapshotWatermark = 0,
    this.error,
  });

  /// Whether [SyncTransport.deleteChanges] was called.
  final bool deleted;

  /// Whether the call was skipped (no snapshot / nothing covered yet).
  final bool skipped;

  /// Own change seq up to which change files were removed.
  final int deletedUpTo;

  /// `snapshot.applied[self]` of the last uploaded snapshot.
  final int snapshotWatermark;

  final Object? error;

  @override
  String toString() =>
      'SyncGcResult(deleted=$deleted skipped=$skipped upTo=$deletedUpTo '
      'watermark=$snapshotWatermark error=$error)';
}

/// Local diagnostics snapshot returned by [SyncEngine.status].
class SyncStatus {
  const SyncStatus({
    required this.localDeviceId,
    required this.protocolVersion,
    required this.applied,
    required this.lastPush,
    required this.lastChange,
    required this.pendingOps,
    required this.lastSnapshot,
    required this.enabledDomains,
    required this.stateDirty,
    required this.checkedAt,
  });

  final String localDeviceId;
  final String protocolVersion;

  /// Applied per-device watermarks (including potentially self).
  final Map<String, int> applied;

  /// Highest own seq that has been uploaded (or replaced by a snapshot).
  final int lastPush;

  /// `lastChange` we report in `devices/<self>.json`.
  final int lastChange;

  /// Number of pending outbox ops.
  final int pendingOps;

  /// Last snapshot uploaded by this device, if any.
  final SnapshotInfo? lastSnapshot;

  final Set<String> enabledDomains;

  /// Whether the remote state document still needs a retry.
  final bool stateDirty;

  final DateTime checkedAt;

  @override
  String toString() =>
      'SyncStatus(device=$localDeviceId lastPush=$lastPush '
      'lastChange=$lastChange pending=$pendingOps '
      'snapshot=$lastSnapshot stateDirty=$stateDirty)';
}

/// Result of [SyncEngine.syncOnce].
class SyncOnceResult {
  const SyncOnceResult({
    required this.pull,
    required this.push,
    required this.snapshot,
  });

  final SyncPullResult pull;
  final SyncPushResult push;
  final SyncSnapshotResult snapshot;

  @override
  String toString() =>
      'SyncOnceResult(pull=$pull, push=$push, snapshot=$snapshot)';
}

/// One candidate snapshot discovered during bootstrap (§7.4).
class _SnapshotCandidate {
  const _SnapshotCandidate({required this.deviceId, required this.info});

  final String deviceId;
  final SnapshotInfo info;
}

/// Mutable accumulator used while a pull walks devices.
class _PullBuilder {
  int devicesInspected = 0;
  int devicesAdvanced = 0;
  int rangesRead = 0;
  int opsRead = 0;
  int opsApplied = 0;
  int opsSkipped = 0;
  int snapshotsApplied = 0;
  int recordsApplied = 0;
  bool changed = false;
  Map<String, int> applied = const <String, int>{};
  final List<SyncPullError> errors = <SyncPullError>[];
  final List<SyncPullError> warnings = <SyncPullError>[];

  SyncPullResult build() => SyncPullResult(
    devicesInspected: devicesInspected,
    devicesAdvanced: devicesAdvanced,
    rangesRead: rangesRead,
    opsRead: opsRead,
    opsApplied: opsApplied,
    opsSkipped: opsSkipped,
    snapshotsApplied: snapshotsApplied,
    recordsApplied: recordsApplied,
    changed: changed,
    applied: applied,
    errors: List<SyncPullError>.unmodifiable(errors),
    warnings: List<SyncPullError>.unmodifiable(warnings),
  );
}

/// Mutable accumulator used while a domain replay walks devices.
class _ReplayBuilder {
  _ReplayBuilder(this.domain);

  final String domain;

  int devicesInspected = 0;
  int rangesRead = 0;
  int opsRead = 0;
  int opsApplied = 0;
  int opsSkipped = 0;
  int snapshotsRead = 0;
  int recordsRead = 0;
  int recordsApplied = 0;
  int clearsApplied = 0;
  bool changed = false;
  Map<String, int> applied = const <String, int>{};
  final List<SyncPullError> errors = <SyncPullError>[];
  final List<SyncPullError> warnings = <SyncPullError>[];

  SyncDomainReplayResult build() => SyncDomainReplayResult(
    domain: domain,
    devicesInspected: devicesInspected,
    rangesRead: rangesRead,
    opsRead: opsRead,
    opsApplied: opsApplied,
    opsSkipped: opsSkipped,
    snapshotsRead: snapshotsRead,
    recordsRead: recordsRead,
    recordsApplied: recordsApplied,
    clearsApplied: clearsApplied,
    changed: changed,
    applied: applied,
    errors: List<SyncPullError>.unmodifiable(errors),
    warnings: List<SyncPullError>.unmodifiable(warnings),
  );
}

/// Orchestrates the v2 sync protocol for one local device.
///
/// Construction does not touch the network; the first public operation calls
/// [SyncStore.init]. Local device id / clock / watermarks are owned by the
/// store, the engine only keeps ephemeral bookkeeping.
class SyncEngine {
  SyncEngine({
    required SyncStore store,
    required SyncTransport transport,
    Set<String> enabledDomains = SyncDomains.all,
    this.snapshotInterval = const Duration(hours: 24),
    this.snapshotChangeThreshold = 200,
    this.pushBatchSize = SyncOpCodec.maxOpsPerBatch,
    this.maxRepairAttempts = 2,
    this.maxBootstrapSnapshots = 2,
    this.compactionPendingThreshold = 5000,
    this.gcRetainChanges = 0,
    this.protocolVersion = syncProtocolVersionTag,
    DateTime Function()? now,
  }) : _store = store,
       _transport = transport,
       _enabledDomains = Set<String>.unmodifiable(enabledDomains),
       _now = now ?? DateTime.now;

  final SyncStore _store;
  final SyncTransport _transport;
  final Set<String> _enabledDomains;
  final DateTime Function() _now;

  /// Period after which a periodic snapshot is generated even without many
  /// changes (§6.2 / §7.2 step 6).
  final Duration snapshotInterval;

  /// Number of pushed changes after which a snapshot is due.
  final int snapshotChangeThreshold;

  /// Maximum number of ops per change file (§6.1: ≤ 2000).
  final int pushBatchSize;

  /// How often a broken change range is repaired from a snapshot before the
  /// pull reports a hard error (prevents bootstrap loops).
  final int maxRepairAttempts;

  /// Upper bound of snapshots applied per bootstrap (§7.4 step 3).
  final int maxBootstrapSnapshots;

  /// Pending outbox size that triggers snapshot substitution (§7.2 step 7).
  final int compactionPendingThreshold;

  /// Trailing own seqs that [gc] keeps even when a snapshot covers them.
  final int gcRetainChanges;

  /// Protocol version string reported by [status].
  final String protocolVersion;

  /// [SyncStore.setMeta] key of the compaction crash-recovery marker
  /// (§7.2 step 7). The value is the JSON object
  /// `{"nextSeq": N, "stage": "snapshot"|"state"}`.
  static const String _metaPendingCompaction = 'pendingCompaction';

  /// Marker stage: snapshot upload and/or state write may still be missing.
  static const String _compactionStageSnapshot = 'snapshot';

  /// Marker stage: snapshot + state are durable, only the outbox clear is
  /// outstanding.
  static const String _compactionStageState = 'state';

  Future<void>? _initFuture;

  /// Serializes public operations (§7.0 single sync executor).
  Future<void> _lock = Future<void>.value();

  bool _closed = false;

  /// Whether `devices/<self>.json` needs to be rewritten (state write failed).
  bool _stateDirty = false;

  /// Best known `RemoteState.lastChange` (last delivered own change seq).
  ///
  /// Contract note: [SyncStore] does not persist `lastChange` separately from
  /// `lastPush`; it is reconstructed from `getLastPush` on [init]. After a
  /// snapshot-substitution compaction that advances `lastPush` to `nextSeq`,
  /// a restart may therefore over-report `lastChange` until the next push;
  /// that only costs other devices an unnecessary snapshot check, never data.
  int _lastChange = 0;

  /// Repair attempts per remote device for the current public operation.
  final Map<String, int> _repairAttempts = <String, int>{};

  /// The local device id (the remote branch this engine writes).
  String get deviceId => _store.deviceId;

  /// Domains this engine produces/applies.
  Set<String> get enabledDomains => _enabledDomains;

  /// The underlying store (exposed for app wiring / tests).
  SyncStore get store => _store;

  /// The underlying transport (exposed for app wiring / tests).
  SyncTransport get transport => _transport;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Initializes the store once. Safe to call repeatedly and from every public
  /// operation; a failed initialization is retried on the next call.
  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = Future<void>(() async {
      await _store.init();
      _lastChange = await _store.getLastPush();
    });
    _initFuture = future;
    // Allow a later call to retry after a transient initialization failure.
    future.catchError((Object _) {
      _initFuture = null;
    });
    return future;
  }

  Future<void> close() => _synchronized(() async {
    if (_closed) return;
    _closed = true;
    try {
      await _transport.close();
    } finally {
      await _store.close();
    }
  });

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final previous = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    return Future<T>(() async {
      try {
        await previous;
        return await action();
      } finally {
        completer.complete();
      }
    });
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('SyncEngine is closed');
    }
  }

  // ---------------------------------------------------------------------------
  // Push (§7.2)
  // ---------------------------------------------------------------------------

  /// Uploads pending outbox ops as one or more change files.
  ///
  /// Order is fixed by the protocol: write the change file first, then trim
  /// the outbox (`markPushed`), then refresh `devices/<self>.json`. A failure
  /// in the last step is not a push failure: the data is already pullable and
  /// [SyncPushResult.stateWritten] is `false` so a later sync retries the
  /// state write.
  Future<SyncPushResult> push() => _synchronized(() async {
    _ensureOpen();
    await init();
    return _push();
  });

  Future<SyncPushResult> _push() async {
    final self = _store.deviceId;
    var batches = 0;
    var opsPushed = 0;
    var lo = 0;
    var hi = 0;
    Object? error;

    while (true) {
      final List<SyncOp> pending;
      try {
        pending = await _store.pendingOps(limit: pushBatchSize);
      } catch (storeError) {
        error = storeError;
        break;
      }
      if (pending.isEmpty) break;

      final batchLo = pending.first.seq;
      final batchHi = pending.last.seq;
      if (batchHi - batchLo + 1 != pending.length) {
        // The outbox contract requires a contiguous seq range. Refuse to send
        // a non-contiguous batch: receivers use the contiguous watermark.
        error = StateError(
          'Outbox range is not contiguous: $batchLo-$batchHi '
          '(${pending.length} ops)',
        );
        break;
      }

      final Uint8List bytes;
      try {
        bytes = SyncOpCodec.encode(pending);
      } catch (encodeError) {
        error = encodeError;
        break;
      }

      try {
        await _transport.writeChanges(self, batchLo, batchHi, bytes);
      } catch (transportError) {
        // Leave the outbox untouched; the next push re-encodes the exact same
        // range and overwrites the (possibly partial) remote file.
        error = transportError;
        break;
      }

      try {
        await _store.markPushed(batchHi);
      } catch (storeError) {
        error = storeError;
        break;
      }

      batches++;
      opsPushed += pending.length;
      _lastChange = math.max(_lastChange, batchHi);
      if (lo == 0) lo = batchLo;
      hi = batchHi;
    }

    var stateWritten = !_stateDirty;
    Object? stateError;
    if (batches > 0 || _stateDirty) {
      final result = await _tryWriteState();
      stateWritten = result.written;
      stateError = result.error;
    }

    return SyncPushResult(
      batches: batches,
      opsPushed: opsPushed,
      lo: lo,
      hi: hi,
      lastPush: await _store.getLastPush(),
      stateWritten: stateWritten,
      error: error,
      stateError: stateError,
    );
  }

  /// Best effort remote state write (§2/§7.2 step 5).
  ///
  /// Never throws: a stale `devices/<self>.json` only loses the fast path of
  /// other devices, `_stateDirty` makes a later sync retry it.
  Future<({bool written, Object? error})> _tryWriteState({
    SnapshotInfo? snapshotOverride,
    int? lastChangeOverride,
  }) async {
    try {
      final self = _store.deviceId;
      final applied = Map<String, int>.from(await _store.getApplied());
      final lastChange = lastChangeOverride ?? _lastChange;
      if (lastChange > (applied[self] ?? 0)) {
        applied[self] = lastChange;
      }
      final snapshot = snapshotOverride ?? await _store.getLastSnapshot();
      final state = RemoteState(
        protocol: syncProtocolVersion,
        deviceId: self,
        updatedHlc: _store.clock.last,
        lastChange: lastChange < 0 ? 0 : lastChange,
        applied: applied,
        snapshot: snapshot,
        lastSeen: _now().toUtc(),
      );
      await _transport.writeState(self, state);
      _stateDirty = false;
      return (written: true, error: null);
    } catch (error) {
      _stateDirty = true;
      return (written: false, error: error);
    }
  }

  // ---------------------------------------------------------------------------
  // Pull (§7.3)
  // ---------------------------------------------------------------------------

  /// Merges all remote devices' missing change files.
  ///
  /// A broken/unavailable change range is repaired from the device's snapshot
  /// (§7.4) before the pull reports an error; local data is never advanced
  /// before the corresponding ops were applied atomically.
  Future<SyncPullResult> pull() => _synchronized(() async {
    _ensureOpen();
    await init();
    _repairAttempts.clear();
    return _pullInternal();
  });

  Future<SyncPullResult> _pullInternal() async {
    final builder = _PullBuilder();
    final List<RemoteDeviceInfo> devices;
    try {
      devices = await _transport.listDevices();
    } catch (error) {
      builder.errors.add(
        SyncPullError(
          deviceId: _store.deviceId,
          message: 'listDevices failed',
          error: error,
        ),
      );
      return builder.build();
    }
    final self = _store.deviceId;
    final seen = <String>{};
    for (final device in devices) {
      final remote = device.deviceId;
      if (remote == self || !seen.add(remote)) continue;
      // Remote device ids become path segments; never trust them (§12.3).
      if (!hlcDeviceIdRegExp.hasMatch(remote)) continue;
      try {
        await _pullDevice(remote, builder);
      } catch (error) {
        builder.errors.add(
          SyncPullError(
            deviceId: remote,
            message: 'Unexpected pull failure',
            error: error,
          ),
        );
      }
    }
    builder.applied = await _store.getApplied();
    return builder.build();
  }

  Future<void> _pullDevice(String remote, _PullBuilder builder) async {
    builder.devicesInspected++;
    // At most two passes: the second one runs after a successful snapshot
    // repair so the remaining (or now-covered) ranges can be applied.
    for (var pass = 0; pass < 2; pass++) {
      RemoteState? state;
      Object? stateError;
      try {
        state = await _transport.readState(remote);
      } catch (error) {
        // A corrupt state document is only a lost hint (§7.3); fall back to
        // the directory listing below.
        stateError = error;
      }

      List<ChangeRange>? ranges;
      Object? rangesError;
      try {
        ranges = await _transport.listChanges(remote);
      } catch (error) {
        rangesError = error;
      }

      SnapshotInfo? remoteSnapshot = state?.snapshot;
      if (remoteSnapshot == null) {
        try {
          remoteSnapshot = await _transport.readSnapshotInfo(remote);
        } catch (_) {
          // Snapshot metadata is optional; change files still drive the merge.
        }
      }

      final applied = await _store.getAppliedSeq(remote);
      var target = state?.lastChange ?? 0;
      final snapshotWatermark = remoteSnapshot?.applied[remote] ?? 0;
      if (snapshotWatermark > target) target = snapshotWatermark;
      if (ranges != null && ranges.isNotEmpty && ranges.last.hi > target) {
        // `state` is a hint, not correctness (§0.3/§7.3): a stale state must
        // not hide change files that are already visible in the listing.
        target = ranges.last.hi;
      }
      if (target <= applied) return;

      if (stateError != null) {
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: 'Unreadable remote state; used change listing instead',
            error: stateError,
          ),
        );
      }

      if (rangesError != null) {
        // Neither state nor listing is usable: skip the device and wait for it
        // to recover instead of guessing ranges (§7.3 step 2).
        builder.errors.add(
          SyncPullError(
            deviceId: remote,
            message: 'listChanges failed',
            error: rangesError,
          ),
        );
        return;
      }

      final available = ranges ?? const <ChangeRange>[];
      var current = applied;
      var gap = false;
      Object? applyError;
      var rangesRead = 0;

      for (final range in available) {
        if (range.hi <= current) continue;
        if (range.lo > current + 1) {
          // Missing file(s) between the applied watermark and this range.
          gap = true;
          break;
        }
        Uint8List? bytes;
        List<SyncOp> ops;
        try {
          bytes = await _transport.readChanges(remote, range);
          if (bytes == null) {
            gap = true;
            break;
          }
          ops = SyncOpCodec.decode(
            bytes,
            expectedDeviceId: remote,
            lo: range.lo,
            hi: range.hi,
          );
        } catch (_) {
          // Missing, truncated or corrupt file: §7.3 requires gap repair via a
          // snapshot. Never apply a partially decoded file.
          gap = true;
          break;
        }
        rangesRead++;
        builder.opsRead += ops.length;

        final fresh = ops
            .where((op) => op.seq > current)
            .toList(growable: false);
        final toApply = fresh
            .where((op) => _enabledDomains.contains(op.domain))
            .toList(growable: false);
        builder.opsSkipped += fresh.length - toApply.length;
        if (toApply.isNotEmpty) {
          try {
            final stats = await _store.applyOps(toApply);
            builder.opsApplied += stats.applied;
            builder.opsSkipped += stats.total - stats.applied;
            if (stats.applied > 0) builder.changed = true;
          } catch (error) {
            applyError = error;
            break;
          }
        }
        // Advance the watermark even when the whole file was filtered out: a
        // disabled/unknown domain must not pin the watermark forever (§7.3).
        try {
          await _store.setApplied(remote, range.hi);
        } catch (error) {
          applyError = error;
          break;
        }
        current = range.hi;
        if (current >= target) break;
      }
      builder.rangesRead += rangesRead;

      if (applyError != null) {
        builder.errors.add(
          SyncPullError(
            deviceId: remote,
            message: 'Failed to apply change data',
            error: applyError,
          ),
        );
        return;
      }
      if (!gap && current >= target) {
        builder.devicesAdvanced++;
        return;
      }

      // Gap repair (§7.4): apply the device's snapshot, then retry once.
      final before = await _store.getAppliedSeq(remote);
      final repaired = await _repairFromSnapshot(remote, builder);
      final after = await _store.getAppliedSeq(remote);
      if (pass == 0 && repaired && after > before) {
        continue;
      }
      builder.errors.add(
        SyncPullError(
          deviceId: remote,
          message:
              'Change range gap could not be repaired '
              '(applied=$before target=$target)',
        ),
      );
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Domain replay (§3.4 / §7.4 step 4)
  // ---------------------------------------------------------------------------

  /// Rebuilds one domain from every retained remote artifact (§3.4, §7.4
  /// step 4).
  ///
  /// Unlike [pull] this ignores this device's applied watermarks: it re-reads
  /// **all** retained change files of every other device and, when those were
  /// pruned by [compactSnapshotIfNeeded]/[gc], replays the device snapshot as
  /// well. Only ops/records of [domain] reach the store, and watermarks are
  /// never advanced, so a later regular [pull] stays consistent.
  ///
  /// This is the data half of the "re-enable sync login state" flow (§3.4):
  /// the caller enables the domain, calls `replayDomain`, lets the app adapters
  /// project the merged state, and only then emits the remaining differences.
  /// Snapshot records/clears are converted to regular ops and applied through
  /// [SyncStore.applyOps], so no snapshot watermark is merged either. The
  /// conversion is lossless for live registers (`upsert`), set elements
  /// (`add`), tombstones (`del` at [SnapshotRecord.deletedVersion]) and
  /// domain-wide cutoffs (`clear`).
  ///
  /// Every remote device and file is handled in isolation: unreadable change
  /// files, snapshots or state documents become per-device
  /// [SyncDomainReplayResult.warnings] and a device that cannot be read at all
  /// is reported instead of failing the whole replay. Throws [ArgumentError]
  /// for a syntactically invalid [domain].
  ///
  /// Note: replay is an explicit operator action; the requested [domain] is
  /// applied even when it is not part of [enabledDomains]. Callers must not
  /// request a domain the device keeps local (protocol §3.2/§3.4).
  Future<SyncDomainReplayResult> replayDomain(String domain) =>
      _synchronized(() async {
        _ensureOpen();
        await init();
        return _replayDomain(domain);
      });

  Future<SyncDomainReplayResult> _replayDomain(String domain) async {
    if (!syncDomainRegExp.hasMatch(domain)) {
      throw ArgumentError.value(domain, 'domain', 'Invalid sync domain');
    }
    final builder = _ReplayBuilder(domain);
    final List<RemoteDeviceInfo> devices;
    try {
      devices = await _transport.listDevices();
    } catch (error) {
      builder.errors.add(
        SyncPullError(
          deviceId: _store.deviceId,
          message: 'listDevices failed',
          error: error,
        ),
      );
      return builder.build();
    }
    final self = _store.deviceId;
    final seen = <String>{};
    for (final device in devices) {
      final remote = device.deviceId;
      if (remote == self || !seen.add(remote)) continue;
      // Remote device ids become path segments; never trust them (§12.3).
      if (!hlcDeviceIdRegExp.hasMatch(remote)) continue;
      builder.devicesInspected++;
      try {
        await _replayDevice(remote, domain, builder);
      } catch (error) {
        builder.errors.add(
          SyncPullError(
            deviceId: remote,
            message: 'Unexpected replay failure',
            error: error,
          ),
        );
      }
    }
    builder.applied = await _store.getApplied();
    return builder.build();
  }

  Future<void> _replayDevice(
    String remote,
    String domain,
    _ReplayBuilder builder,
  ) async {
    // The state document is only a hint (§0.3, §7.3); replay must not depend
    // on it. A corrupt state still lets us walk the change listing/snapshot.
    RemoteState? state;
    try {
      state = await _transport.readState(remote);
    } catch (error) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'Unreadable remote state during replay',
          error: error,
        ),
      );
    }

    List<ChangeRange>? ranges;
    Object? rangesError;
    try {
      ranges = await _transport.listChanges(remote);
    } catch (error) {
      rangesError = error;
    }
    if (rangesError != null) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'listChanges failed during replay; using the snapshot',
          error: rangesError,
        ),
      );
    }

    // A pruned/partial change history needs the snapshot: an empty listing, a
    // hole between retained ranges, a missing prefix (GC) or an advertised
    // watermark the retained ranges do not cover.
    var needSnapshot = ranges == null || ranges.isEmpty;
    var expected = 1;
    var retainedHi = 0;
    for (final range in ranges ?? const <ChangeRange>[]) {
      if (range.hi < range.lo) {
        needSnapshot = true;
        continue;
      }
      if (range.lo > expected) needSnapshot = true;
      final readable = await _replayChangeRange(remote, range, domain, builder);
      if (!readable) needSnapshot = true;
      if (range.hi >= expected) expected = range.hi + 1;
      if (range.hi > retainedHi) retainedHi = range.hi;
    }
    final advertised = state?.lastChange ?? 0;
    final snapshotWatermark = state?.snapshot?.applied[remote] ?? 0;
    if (advertised > retainedHi || snapshotWatermark > retainedHi) {
      needSnapshot = true;
    }
    if (!needSnapshot) return;

    await _replaySnapshot(remote, domain, builder);
  }

  /// Replays one retained change file, filtered to [domain]. Returns `false`
  /// when the file is missing or unreadable (a gap the snapshot must cover).
  Future<bool> _replayChangeRange(
    String remote,
    ChangeRange range,
    String domain,
    _ReplayBuilder builder,
  ) async {
    final List<SyncOp> ops;
    try {
      final bytes = await _transport.readChanges(remote, range);
      if (bytes == null) {
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: 'Change file $range is missing during replay',
          ),
        );
        return false;
      }
      ops = SyncOpCodec.decode(
        bytes,
        expectedDeviceId: remote,
        lo: range.lo,
        hi: range.hi,
      );
    } catch (error) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'Unreadable change file $range during replay',
          error: error,
        ),
      );
      return false;
    }
    builder.rangesRead++;
    builder.opsRead += ops.length;
    final toApply = ops
        .where((op) => op.domain == domain)
        .toList(growable: false);
    builder.opsSkipped += ops.length - toApply.length;
    if (toApply.isEmpty) return true;
    try {
      // Replayed through the regular merge path, but without a watermark
      // update: the replay is a local state rebuild, not a delivery cursor.
      final stats = await _store.applyOps(toApply);
      builder.opsApplied += stats.applied;
      builder.opsSkipped += stats.total - stats.applied;
      if (stats.applied > 0) builder.changed = true;
    } catch (error) {
      builder.errors.add(
        SyncPullError(
          deviceId: remote,
          message: 'Failed to apply replayed change data',
          error: error,
        ),
      );
      return false;
    }
    return true;
  }

  /// Fallback for a device whose change files were pruned: converts the
  /// snapshot records/clears of [domain] into regular ops and applies them.
  ///
  /// Watermarks advertised by the snapshot are deliberately ignored; only
  /// records and cutoffs are replayed.
  Future<void> _replaySnapshot(
    String remote,
    String domain,
    _ReplayBuilder builder,
  ) async {
    SnapshotInfo? info;
    try {
      info = await _transport.readSnapshotInfo(remote);
    } catch (error) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'Unreadable snapshot metadata during replay',
          error: error,
        ),
      );
    }
    if (info != null) {
      if (info.deviceId != remote) {
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: 'Replayed snapshot belongs to ${info.deviceId}',
          ),
        );
        return;
      }
      if (info.protocol > syncProtocolVersion) {
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: 'Unsupported snapshot protocol ${info.protocol}',
          ),
        );
        return;
      }
      if (!info.domains.contains(domain)) {
        // No retained artifact carries the domain: the caller has to fall back
        // to a local rebuild (protocol §3.4), the replay cannot invent data.
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: "Snapshot does not cover domain '$domain'",
          ),
        );
        return;
      }
    }

    Uint8List? bytes;
    try {
      bytes = await _transport.readSnapshot(remote);
    } catch (error) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'Unreadable snapshot during replay',
          error: error,
        ),
      );
      return;
    }
    if (bytes == null) return;

    final ParsedSnapshot parsed;
    try {
      parsed = SnapshotCodec.decode(bytes, expectedDeviceId: remote);
    } catch (error) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'Unusable snapshot during replay',
          error: error,
        ),
      );
      return;
    }
    builder.snapshotsRead++;

    // Clears first: they are persistent cutoffs and must dominate late records
    // (§3.1/D11). Applying them as ops keeps the snapshot watermarks local-only.
    final cutoff = parsed.clears[domain];
    if (cutoff != null) {
      SyncOp? clearOp;
      try {
        clearOp = _snapshotClearToOp(domain, cutoff);
      } catch (error) {
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: 'Unusable snapshot clear for $domain',
            error: error,
          ),
        );
      }
      if (clearOp != null) {
        try {
          final stats = await _store.applyOps(<SyncOp>[clearOp]);
          builder.clearsApplied += stats.applied;
          if (stats.applied > 0) builder.changed = true;
        } catch (error) {
          builder.errors.add(
            SyncPullError(
              deviceId: remote,
              message: 'Failed to apply replayed clear for $domain',
              error: error,
            ),
          );
          return;
        }
      }
    }

    final ops = <SyncOp>[];
    for (final record in parsed.records) {
      if (record.domain != domain) continue;
      builder.recordsRead++;
      try {
        final op = _snapshotRecordToOp(record);
        if (op == null) {
          builder.warnings.add(
            SyncPullError(
              deviceId: remote,
              message: 'Skipped unusable snapshot record ${record.key}',
            ),
          );
          continue;
        }
        ops.add(op);
      } catch (error) {
        builder.warnings.add(
          SyncPullError(
            deviceId: remote,
            message: 'Unusable snapshot record ${record.key}',
            error: error,
          ),
        );
      }
    }

    for (
      var start = 0;
      start < ops.length;
      start += SyncOpCodec.maxOpsPerBatch
    ) {
      final end = math.min(start + SyncOpCodec.maxOpsPerBatch, ops.length);
      final chunk = ops.sublist(start, end);
      try {
        final stats = await _store.applyOps(chunk);
        builder.recordsApplied += stats.applied;
        if (stats.applied > 0) builder.changed = true;
      } catch (error) {
        builder.errors.add(
          SyncPullError(
            deviceId: remote,
            message: 'Failed to apply replayed snapshot records',
            error: error,
          ),
        );
        return;
      }
    }
  }

  /// Converts one snapshot record into the equivalent [SyncOp].
  ///
  /// A hidden record (its delete version is not older than its value version)
  /// becomes a `del` carrying [SnapshotRecord.deletedVersion]; otherwise the
  /// field group's merge rule decides between a set `add` and a register
  /// `upsert`. Returns `null` when the record cannot be represented as an op
  /// (non-positive seq, invalid device id).
  SyncOp? _snapshotRecordToOp(SnapshotRecord record) {
    final deleted = record.deletedVersion;
    final hidden = deleted != null && record.version.compareTo(deleted) <= 0;
    final version = hidden ? deleted : record.version;
    if (version.seq <= 0 || !hlcDeviceIdRegExp.hasMatch(version.hlc.deviceId)) {
      return null;
    }
    final SyncOpKind kind;
    if (hidden) {
      kind = SyncOpKind.del;
    } else if (_isSetElement(record)) {
      kind = SyncOpKind.add;
    } else {
      kind = SyncOpKind.upsert;
    }
    return SyncOp(
      deviceId: version.hlc.deviceId,
      seq: version.seq,
      version: version,
      domain: record.domain,
      key: record.key,
      field: record.field,
      kind: kind,
      data: kind == SyncOpKind.upsert ? record.data : null,
    );
  }

  /// Whether the record's field group is LWW-Element-Set membership.
  ///
  /// Unknown (future) domains degrade to register semantics, matching
  /// [SyncDomains.ruleForField]'s forward-compatible handling of unknown
  /// named field groups.
  bool _isSetElement(SnapshotRecord record) {
    try {
      return SyncDomains.ruleForField(record.domain, record.field) ==
          MergeRule.setLwwElement;
    } on ArgumentError {
      return false;
    }
  }

  SyncOp? _snapshotClearToOp(String domain, Version cutoff) {
    if (cutoff.seq <= 0 || !hlcDeviceIdRegExp.hasMatch(cutoff.hlc.deviceId)) {
      return null;
    }
    return SyncOp(
      deviceId: cutoff.hlc.deviceId,
      seq: cutoff.seq,
      version: cutoff,
      domain: domain,
      key: null,
      field: '',
      kind: SyncOpKind.clear,
    );
  }

  // ---------------------------------------------------------------------------
  // Bootstrap / gap repair (§7.4)
  // ---------------------------------------------------------------------------

  /// Repairs missing data from other devices' snapshots, then runs an
  /// incremental [pull].
  ///
  /// When [deviceId] is given only that device's snapshot is considered
  /// (targeted gap repair); otherwise the best global candidate is chosen by
  /// per-device watermark coverage and snapshot HLC (§7.4 step 1). Snapshots
  /// are merged with LWW/max semantics, so the call is idempotent and safe on a
  /// partially populated local store.
  Future<SyncBootstrapResult> bootstrap({String? deviceId}) =>
      _synchronized(() async {
        _ensureOpen();
        await init();
        _repairAttempts.clear();
        final repaired = await _bootstrapInternal(deviceId: deviceId);
        final pullResult = await _pullInternal();
        return SyncBootstrapResult(
          deviceId: deviceId,
          candidates: repaired.candidates,
          snapshotsApplied: repaired.snapshotsApplied,
          recordsConsidered: repaired.recordsConsidered,
          recordsApplied: repaired.recordsApplied,
          clearsConsidered: repaired.clearsConsidered,
          missingDomains: repaired.missingDomains,
          error: repaired.error,
          pull: pullResult,
        );
      });

  Future<bool> _repairFromSnapshot(String remote, _PullBuilder builder) async {
    final attempts = _repairAttempts[remote] ?? 0;
    if (attempts >= maxRepairAttempts) return false;
    _repairAttempts[remote] = attempts + 1;
    final result = await _bootstrapInternal(deviceId: remote);
    builder.snapshotsApplied += result.snapshotsApplied;
    builder.recordsApplied += result.recordsApplied;
    if (result.error != null) {
      builder.warnings.add(
        SyncPullError(
          deviceId: remote,
          message: 'Snapshot repair failed',
          error: result.error,
        ),
      );
    }
    return result.snapshotsApplied > 0;
  }

  Future<SyncBootstrapResult> _bootstrapInternal({String? deviceId}) async {
    final List<RemoteDeviceInfo> devices;
    try {
      devices = await _transport.listDevices();
    } catch (error) {
      return SyncBootstrapResult(deviceId: deviceId, error: error);
    }

    final self = _store.deviceId;
    final candidates = <_SnapshotCandidate>[];
    final seen = <String>{};
    for (final device in devices) {
      final remote = device.deviceId;
      if (!hlcDeviceIdRegExp.hasMatch(remote) || !seen.add(remote)) continue;
      if (deviceId != null) {
        if (remote != deviceId) continue;
      } else if (remote == self) {
        // Applying our own snapshot cannot add local data; skip the download.
        continue;
      }

      RemoteState? state;
      try {
        state = await _transport.readState(remote);
      } catch (_) {
        // Fall through to the snapshot metadata probe.
      }
      var info = state?.snapshot;
      if (info == null) {
        try {
          info = await _transport.readSnapshotInfo(remote);
        } catch (_) {
          info = null;
        }
      }
      if (info == null) continue;
      // The snapshot must belong to the device that advertises it.
      if (info.deviceId != remote) continue;
      if (info.protocol > syncProtocolVersion) continue;
      candidates.add(_SnapshotCandidate(deviceId: remote, info: info));
    }
    candidates.sort(_compareSnapshotCandidates);

    var snapshotsApplied = 0;
    var recordsConsidered = 0;
    var recordsApplied = 0;
    var clearsConsidered = 0;
    final missingDomains = Set<String>.of(_enabledDomains);
    Object? lastError;
    final tried = <String>{};

    for (final candidate in candidates) {
      if (snapshotsApplied >= maxBootstrapSnapshots) break;
      if (!tried.add(candidate.deviceId)) continue;

      Uint8List? bytes;
      try {
        bytes = await _transport.readSnapshot(candidate.deviceId);
      } catch (error) {
        lastError = error;
      }
      if (bytes == null) continue;

      final ParsedSnapshot parsed;
      try {
        parsed = SnapshotCodec.decode(
          bytes,
          expectedDeviceId: candidate.deviceId,
        );
      } catch (error) {
        // Unusable snapshot (corrupt/truncated/device mismatch): §6.3/§7.4
        // says to try the next candidate instead of failing the sync.
        lastError = error;
        continue;
      }

      final SyncApplyStats stats;
      try {
        stats = await _store.applySnapshot(
          parsed,
          enabledDomains: _enabledDomains,
        );
      } catch (error) {
        return SyncBootstrapResult(
          deviceId: deviceId,
          candidates: candidates.length,
          snapshotsApplied: snapshotsApplied,
          recordsConsidered: recordsConsidered,
          recordsApplied: recordsApplied,
          clearsConsidered: clearsConsidered,
          error: error,
        );
      }

      snapshotsApplied++;
      recordsConsidered += parsed.records.length;
      recordsApplied += stats.applied;
      clearsConsidered += parsed.clears.length;
      // Domains covered by at least one applied snapshot no longer need a
      // rebuild (§7.4 step 4); the rest is reported to the caller.
      missingDomains.removeAll(parsed.info.domains);
    }

    return SyncBootstrapResult(
      deviceId: deviceId,
      candidates: candidates.length,
      snapshotsApplied: snapshotsApplied,
      recordsConsidered: recordsConsidered,
      recordsApplied: recordsApplied,
      clearsConsidered: clearsConsidered,
      missingDomains: snapshotsApplied == 0
          ? const <String>{}
          : Set<String>.unmodifiable(missingDomains),
      error: snapshotsApplied == 0 ? lastError : null,
    );
  }

  /// Orders snapshot candidates per §7.4 step 1:
  ///  1. snapshots covering all enabled domains first,
  ///  2. then more complete per-device applied watermarks,
  ///  3. then the newer snapshot HLC,
  ///  4. then the device id for determinism.
  int _compareSnapshotCandidates(_SnapshotCandidate a, _SnapshotCandidate b) {
    final aCovers = _enabledDomains.difference(a.info.domains).isEmpty;
    final bCovers = _enabledDomains.difference(b.info.domains).isEmpty;
    if (aCovers != bCovers) return aCovers ? -1 : 1;

    final devices = <String>{
      ...a.info.applied.keys,
      ...b.info.applied.keys,
    }.toList()..sort();
    for (final device in devices) {
      final aWatermark = a.info.applied[device] ?? 0;
      final bWatermark = b.info.applied[device] ?? 0;
      if (aWatermark != bWatermark) return bWatermark.compareTo(aWatermark);
    }

    final hlcOrder = b.info.hlc.compareTo(a.info.hlc);
    if (hlcOrder != 0) return hlcOrder;
    return a.deviceId.compareTo(b.deviceId);
  }

  // ---------------------------------------------------------------------------
  // Snapshot (§6.2 / §7.2 step 6)
  // ---------------------------------------------------------------------------

  /// Builds and uploads a periodic snapshot of the local merged state.
  ///
  /// `snapshot.applied[self]` is set to [SyncStore.getLastPush], **not** to
  /// [SyncStore.getNextSeq]: unpushed pending ops may still be rewritten in
  /// place and re-sent as changes, so advancing the self watermark to nextSeq
  /// here would make receivers skip those changes (§7.2 step 6).
  Future<SyncSnapshotResult> snapshot() => _synchronized(() async {
    _ensureOpen();
    await init();
    return _writePeriodicSnapshot();
  });

  Future<SyncSnapshotResult> _writePeriodicSnapshot() async {
    final lastPush = await _store.getLastPush();
    return _writeSnapshotData(
      selfWatermark: lastPush,
      rangeHi: math.max(1, lastPush),
    );
  }

  /// Generates a snapshot only when the periodic policy says it is due:
  /// no snapshot yet, [snapshotChangeThreshold] pushed changes since the last
  /// one, or [snapshotInterval] elapsed since the last snapshot HLC.
  Future<SyncSnapshotResult> maybeSnapshot() => _synchronized(() async {
    _ensureOpen();
    await init();
    return _maybeSnapshotInternal();
  });

  Future<SyncSnapshotResult> _maybeSnapshotInternal() async {
    final lastSnapshot = await _store.getLastSnapshot();
    if (lastSnapshot == null) {
      // Seed the first snapshot so other devices can bootstrap from us
      // (§7.4 step 4).
      return _writePeriodicSnapshot();
    }
    final lastPush = await _store.getLastPush();
    if (lastPush - lastSnapshot.rangeHi >= snapshotChangeThreshold) {
      return _writePeriodicSnapshot();
    }
    final elapsed = _now().toUtc().millisecondsSinceEpoch - lastSnapshot.hlc.ms;
    if (elapsed >= snapshotInterval.inMilliseconds) {
      return _writePeriodicSnapshot();
    }
    return const SyncSnapshotResult(skipped: true);
  }

  /// Snapshot substitution for an oversized outbox (§7.2 step 7).
  ///
  /// Separate from the periodic snapshot on purpose: a substitution snapshot
  /// takes `N = getNextSeq()` (including not-yet-uploaded pending ops) as the
  /// self watermark, because the snapshot replaces those changes entirely.
  /// `state.lastChange` is kept at the actually delivered change seq.
  ///
  /// Contract limitation: [SyncStore] has no "freeze in-place coalescing" hook
  /// and [SyncStore.dumpRecords] is not guaranteed to be taken at the same
  /// instant as [SyncStore.getNextSeq]; a concurrent local write between the
  /// two calls would be included in both the snapshot and the pending outbox.
  /// That is safe for receivers (its seq is > N, re-sent as a change and the
  /// snapshot apply is idempotent), only the outbox is not fully trimmed. A
  /// proper `pendingCompaction` marker needs a store contract extension; see
  /// the task report.
  Future<SyncSnapshotResult> compactSnapshotIfNeeded() =>
      _synchronized(() async {
        _ensureOpen();
        await init();
        return _compactSnapshotIfNeeded();
      });

  Future<SyncSnapshotResult> _compactSnapshotIfNeeded() async {
    final pending = await _store.pendingCount();
    if (pending <= 0 || pending < compactionPendingThreshold) {
      return const SyncSnapshotResult(skipped: true);
    }
    final delivered = await _store.getLastPush();
    final nextSeq = await _store.getNextSeq();
    if (nextSeq <= delivered) {
      return const SyncSnapshotResult(skipped: true);
    }
    // Keep reporting the last actually delivered change seq; the snapshot, not
    // a change file, covers seqs delivered+1 .. nextSeq from now on.
    _lastChange = math.max(_lastChange, delivered);
    // Crash-recovery marker (§7.2 step 7): snapshot → state → clear outbox.
    // If the process dies anywhere here, recoverPendingCompaction() resumes
    // idempotently on the next start.
    await _store.setMeta(
      _metaPendingCompaction,
      jsonEncode({'nextSeq': nextSeq, 'stage': _compactionStageSnapshot}),
    );
    final result = await _writeSnapshotData(
      selfWatermark: nextSeq,
      rangeHi: math.max(1, nextSeq),
      stateLastChange: _lastChange,
    );
    if (result.written && result.stateWritten) {
      await _store.setMeta(
        _metaPendingCompaction,
        jsonEncode({'nextSeq': nextSeq, 'stage': _compactionStageState}),
      );
      try {
        await _store.markPushed(nextSeq);
        await _store.setMeta(_metaPendingCompaction, null);
      } catch (error) {
        return SyncSnapshotResult(
          info: result.info,
          records: result.records,
          clears: result.clears,
          written: result.written,
          stateWritten: result.stateWritten,
          error: error,
          stateError: result.stateError,
        );
      }
    }
    return result;
  }

  /// Resumes a compaction that crashed between snapshot / state / outbox
  /// clearing. Safe to call on every start; returns `null` when there is no
  /// marker.
  Future<SyncSnapshotResult?> recoverPendingCompaction() =>
      _synchronized(() async {
        _ensureOpen();
        await init();
        final raw = await _store.getMeta(_metaPendingCompaction);
        if (raw == null) return null;
        int nextSeq;
        String stage;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) throw const FormatException('not a map');
          nextSeq = decoded['nextSeq'] as int;
          stage = decoded['stage'] as String? ?? _compactionStageSnapshot;
        } catch (_) {
          await _store.setMeta(_metaPendingCompaction, null);
          return null;
        }
        if (nextSeq <= 0) {
          await _store.setMeta(_metaPendingCompaction, null);
          return null;
        }
        if (stage == _compactionStageState) {
          // Snapshot + state are durable; only the outbox clear is missing.
          await _store.markPushed(nextSeq);
          await _store.setMeta(_metaPendingCompaction, null);
          return const SyncSnapshotResult(skipped: true);
        }
        // Snapshot may be missing/incomplete; re-upload it idempotently.
        final delivered = await _store.getLastPush();
        _lastChange = math.max(_lastChange, delivered);
        final result = await _writeSnapshotData(
          selfWatermark: nextSeq,
          rangeHi: math.max(1, nextSeq),
          stateLastChange: _lastChange,
        );
        if (result.written && result.stateWritten) {
          await _store.setMeta(
            _metaPendingCompaction,
            jsonEncode({'nextSeq': nextSeq, 'stage': _compactionStageState}),
          );
          await _store.markPushed(nextSeq);
          await _store.setMeta(_metaPendingCompaction, null);
        }
        return result;
      });

  Future<SyncSnapshotResult> _writeSnapshotData({
    required int selfWatermark,
    required int rangeHi,
    int? stateLastChange,
  }) async {
    final self = _store.deviceId;
    try {
      final records = <SnapshotRecord>[];
      for (final record in await _store.dumpRecords(domains: _enabledDomains)) {
        // Defence in depth: the store already filters by domain, the codec
        // additionally requires every record domain to be declared.
        if (!_enabledDomains.contains(record.domain)) continue;
        if (!syncDomainRegExp.hasMatch(record.domain)) continue;
        records.add(
          SnapshotRecord(
            domain: record.domain,
            key: record.key,
            field: record.field,
            version: record.version,
            deletedVersion: record.deletedVersion,
            data: record.data,
          ),
        );
      }

      final clears = <String, Version>{};
      for (final clear in await _store.dumpClears(domains: _enabledDomains)) {
        if (!_enabledDomains.contains(clear.domain)) continue;
        final previous = clears[clear.domain];
        if (previous == null || clear.cutoff > previous) {
          clears[clear.domain] = clear.cutoff;
        }
      }

      // Only declare domains that actually carry data; a domain without any
      // record/tombstone/clear would otherwise claim coverage it cannot give.
      final domains = <String>{
        for (final record in records) record.domain,
        ...clears.keys,
      };

      final applied = Map<String, int>.from(await _store.getApplied());
      final previousSelf = applied[self] ?? 0;
      if (selfWatermark > previousSelf) applied[self] = selfWatermark;

      final info = SnapshotInfo(
        protocol: syncProtocolVersion,
        schema: syncProtocolVersion,
        deviceId: self,
        // meta HLC must be greater than every record HLC in the snapshot
        // (§6.2); tickHlcForMeta does not emit an op.
        hlc: await _store.tickHlcForMeta(),
        rangeLo: 1,
        rangeHi: rangeHi,
        applied: applied,
        domains: domains,
      );

      final Uint8List bytes;
      try {
        bytes = SnapshotCodec.encode(info, clears, records);
      } catch (error) {
        return SyncSnapshotResult(
          info: info,
          records: records.length,
          clears: clears.length,
          error: error,
        );
      }

      try {
        await _transport.writeSnapshot(self, bytes);
      } catch (error) {
        return SyncSnapshotResult(
          info: info,
          records: records.length,
          clears: clears.length,
          error: error,
        );
      }

      // Protocol order (§7.2 step 6): snapshot data first, then the state
      // pointer, and only then track it as our last snapshot. The local
      // pointer is recorded even when the state write fails: the snapshot
      // itself is already durable and a retried state write advertises it.
      final stateResult = await _tryWriteState(
        snapshotOverride: info,
        lastChangeOverride: stateLastChange,
      );
      await _store.setLastSnapshot(info);
      return SyncSnapshotResult(
        info: info,
        records: records.length,
        clears: clears.length,
        written: true,
        stateWritten: stateResult.written,
        stateError: stateResult.error,
      );
    } catch (error) {
      return SyncSnapshotResult(error: error);
    }
  }

  // ---------------------------------------------------------------------------
  // GC (§7.6)
  // ---------------------------------------------------------------------------

  /// Deletes own change files covered by the last uploaded snapshot.
  ///
  /// This is the §7.6 policy: once `snapshot.applied[self] = W`, change files
  /// with `hi <= W` are no longer needed for bootstrap (slow devices repair via
  /// the snapshot). [gcRetainChanges] can keep a tail of change seqs as a
  /// grace window.
  Future<SyncGcResult> gc() => _synchronized(() async {
    _ensureOpen();
    await init();
    return _gc();
  });

  Future<SyncGcResult> _gc() async {
    final SnapshotInfo? snapshot;
    try {
      snapshot = await _store.getLastSnapshot();
    } catch (error) {
      return SyncGcResult(error: error);
    }
    if (snapshot == null) {
      return const SyncGcResult(skipped: true);
    }
    final watermark = snapshot.applied[_store.deviceId] ?? 0;
    final upTo = watermark - gcRetainChanges;
    if (upTo <= 0) {
      return SyncGcResult(skipped: true, snapshotWatermark: watermark);
    }
    try {
      await _transport.deleteChanges(_store.deviceId, upTo);
    } catch (error) {
      return SyncGcResult(snapshotWatermark: watermark, error: error);
    }
    return SyncGcResult(
      deleted: true,
      deletedUpTo: upTo,
      snapshotWatermark: watermark,
    );
  }

  // ---------------------------------------------------------------------------
  // High level / diagnostics
  // ---------------------------------------------------------------------------

  /// One full sync cycle: pull, then push, then a snapshot if due (§7.2/§7.3).
  Future<SyncOnceResult> syncOnce() => _synchronized(() async {
    _ensureOpen();
    await init();
    _repairAttempts.clear();
    final pullResult = await _pullInternal();
    final pushResult = await _push();
    final snapshotResult = await _maybeSnapshotInternal();
    return SyncOnceResult(
      pull: pullResult,
      push: pushResult,
      snapshot: snapshotResult,
    );
  });

  /// Local sync diagnostics for the settings page (§9).
  Future<SyncStatus> status() async {
    _ensureOpen();
    await init();
    return SyncStatus(
      localDeviceId: _store.deviceId,
      protocolVersion: protocolVersion,
      applied: Map<String, int>.unmodifiable(await _store.getApplied()),
      lastPush: await _store.getLastPush(),
      lastChange: _lastChange,
      pendingOps: await _store.pendingCount(),
      lastSnapshot: await _store.getLastSnapshot(),
      enabledDomains: _enabledDomains,
      stateDirty: _stateDirty,
      checkedAt: _now().toUtc(),
    );
  }
}
