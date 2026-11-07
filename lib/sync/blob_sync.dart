/// Content-addressed blob helpers for the v2 sync protocol (§6.3).
///
/// Blobs (currently the `comicSource` JavaScript files) are stored under the
/// producing device's own branch and are immutable. Records reference them by
/// the sha256 of the *uncompressed* content. This helper bridges the engine's
/// record layer and the transport's blob primitives:
///
///  * [upload] hashes the bytes, skips the upload when the blob already
///    exists on this device and returns the sha256 reference;
///  * [download] verifies the sha256 after reading (rejecting corrupt or
///    malicious content) and can search every visible device branch.
///
/// The optional ledger makes repeated uploads cheap. Without it, every
/// [upload] would download the whole blob back just to check existence —
/// seconds of network per push for a large source list. With it, a blob that
/// was confirmed uploaded once is never probed again (content addressing
/// makes "same sha" and "same bytes" equivalent). [reverifyOldest] keeps the
/// ledger honest: it re-probes a few oldest entries per push, so blobs that
/// disappear from the server (manual pruning) are re-uploaded within minutes.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hlc.dart';
import 'transport.dart';

/// Loads the persisted ledger; `null` when nothing was saved yet.
typedef BlobLedgerLoader = Future<Map<String, int>?> Function();

/// Persists the ledger (sha256 -> last-verified epoch ms).
typedef BlobLedgerSaver = Future<void> Function(Map<String, int> ledger);

class BlobSync {
  BlobSync({
    required this.transport,
    required this.localDeviceId,
    this.ledgerLoader,
    this.ledgerSaver,
    this.ledgerReverifyCount = 2,
    this.ledgerCapacity = 512,
  }) {
    if (!hlcDeviceIdRegExp.hasMatch(localDeviceId)) {
      throw ArgumentError.value(
        localDeviceId,
        'localDeviceId',
        'Invalid device id',
      );
    }
  }

  final SyncTransport transport;
  final String localDeviceId;

  /// Ledger persistence hooks. Without both, the ledger stays in memory for
  /// this instance only (uploads fall back to the probe-then-write path).
  final BlobLedgerLoader? ledgerLoader;
  final BlobLedgerSaver? ledgerSaver;

  /// How many ledger entries [reverifyOldest] re-probes per call.
  final int ledgerReverifyCount;

  /// Upper bound on ledger size; evicted entries simply re-verify on the
  /// next upload instead of breaking anything.
  final int ledgerCapacity;

  Map<String, int>? _ledgerCache;
  Future<Map<String, int>>? _ledgerLoad;
  bool _ledgerBroken = false;

  int _uploadsSinceGc = 0;

  /// Real uploads (network writes) since the last [resetUploadCounter];
  /// callers use it to decide whether blob GC is worth a remote listing.
  int get uploadsSinceLastGc => _uploadsSinceGc;

  void resetUploadCounter() => _uploadsSinceGc = 0;

  static final RegExp sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// sha256 of the uncompressed blob content, as referenced by records.
  static String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

  static void validateSha256(String sha256) {
    if (!sha256Pattern.hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'Invalid sha256');
    }
  }

  Future<Map<String, int>> _loadLedger() async {
    final cached = _ledgerCache;
    if (cached != null) return cached;
    final loading = _ledgerLoad;
    if (loading != null) return loading;
    final future = () async {
      Map<String, int> ledger = <String, int>{};
      if (!_ledgerBroken) {
        try {
          final persisted = await ledgerLoader?.call();
          if (persisted != null) ledger = persisted;
        } catch (_) {
          // An unreadable ledger only costs an extra probe per blob.
          ledger = <String, int>{};
          _ledgerBroken = true;
        }
      }
      return _ledgerCache = ledger;
    }();
    _ledgerLoad = future;
    return future;
  }

  Future<void> _saveLedger(Map<String, int> ledger) async {
    if (ledgerSaver == null) return;
    try {
      await ledgerSaver!.call(ledger);
    } catch (_) {
      // Persistence failures degrade to per-instance memory only.
      _ledgerBroken = true;
    }
  }

  void _remember(Map<String, int> ledger, String sha) {
    final now = DateTime.now().millisecondsSinceEpoch;
    ledger[sha] = now;
    if (ledger.length > ledgerCapacity) {
      final oldest =
          (ledger.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))
              .take(ledger.length - ledgerCapacity)
              .map((entry) => entry.key)
              .toList();
      for (final key in oldest) {
        ledger.remove(key);
      }
    }
    // Not awaited by design: the upload result does not depend on the write,
    // and a lost ledger entry only causes a redundant probe later.
    unawaited(_saveLedger(ledger));
  }

  /// Uploads [bytes] to this device's branch when it is not already present.
  ///
  /// Returns the sha256 reference to store in a record payload. A blob that
  /// the ledger marks as uploaded is returned without any network traffic.
  /// Otherwise an existing remote copy is verified when [verifyExisting] is
  /// true, so a corrupted remote blob is rejected instead of silently kept.
  Future<String> upload(Uint8List bytes, {bool verifyExisting = true}) async {
    final sha = sha256Hex(bytes);
    final ledger = await _loadLedger();
    if (ledger.containsKey(sha)) return sha;
    Uint8List? existing;
    try {
      existing = await transport.readBlob(localDeviceId, sha);
    } on SyncTransportException {
      // A read failure must not prevent the upload; writeBlob is idempotent.
      existing = null;
    }
    if (existing != null) {
      if (verifyExisting && sha256Hex(existing) != sha) {
        throw SyncTransportException(
          'Existing blob $sha is corrupted on $localDeviceId',
        );
      }
      _remember(ledger, sha);
      return sha;
    }
    await transport.writeBlob(localDeviceId, sha, bytes);
    _uploadsSinceGc++;
    _remember(ledger, sha);
    return sha;
  }

  /// Re-probes up to [maxEntries] ledger entries, oldest-verified first, and
  /// removes entries whose blob is gone from the remote branch so the next
  /// [upload] re-sends the content. Returns the number of dropped entries.
  ///
  /// Probe failures keep the entry (the next push retries); only a definitive
  /// "absent" answer invalidates the ledger.
  Future<int> reverifyOldest(int maxEntries) async {
    if (maxEntries <= 0) return 0;
    final ledger = await _loadLedger();
    if (ledger.isEmpty) return 0;
    final entries = ledger.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final now = DateTime.now().millisecondsSinceEpoch;
    var dropped = 0;
    var changed = false;
    for (final entry in entries.take(maxEntries)) {
      bool exists;
      try {
        exists = await transport.blobExists(localDeviceId, entry.key);
      } on SyncTransportException {
        continue;
      }
      if (exists) {
        if (ledger[entry.key] != now) {
          ledger[entry.key] = now;
          changed = true;
        }
      } else {
        ledger.remove(entry.key);
        dropped++;
        changed = true;
      }
    }
    if (changed) await _saveLedger(ledger);
    return dropped;
  }

  /// Reads and verifies a blob produced by [fromDevice].
  ///
  /// Returns `null` when the device does not have it or the branch is not
  /// readable. Throws [SyncTransportException] when the bytes exist but do not
  /// match the requested sha256.
  Future<Uint8List?> download(
    String sha256, {
    required String fromDevice,
  }) async {
    validateSha256(sha256);
    if (!hlcDeviceIdRegExp.hasMatch(fromDevice)) {
      throw ArgumentError.value(fromDevice, 'fromDevice', 'Invalid device id');
    }
    final bytes = await transport.readBlob(fromDevice, sha256);
    if (bytes == null) return null;
    if (sha256Hex(bytes) != sha256) {
      throw SyncTransportException('Blob $sha256 hash mismatch on $fromDevice');
    }
    return bytes;
  }

  /// Searches every visible device branch (local device first) for [sha256].
  ///
  /// Useful when a record references a source file whose producing device is
  /// not known. Returns the verified bytes, or `null` when no branch has them.
  Future<Uint8List?> downloadFromAnyDevice(String sha256) async {
    validateSha256(sha256);
    final tried = <String>{};
    Future<Uint8List?> tryDevice(String deviceId) async {
      if (!tried.add(deviceId)) return null;
      try {
        return await download(sha256, fromDevice: deviceId);
      } on SyncTransportException {
        return null;
      }
    }

    final local = await tryDevice(localDeviceId);
    if (local != null) return local;
    for (final device in await transport.listDevices()) {
      final bytes = await tryDevice(device.deviceId);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Deletes blobs on this device's branch that no record references anymore.
  ///
  /// Immutability makes an unreferenced blob pure garbage: content-addressed
  /// names mean a later record with the same content re-uploads the same name.
  /// Callers must only run this after the references snapshot was uploaded
  /// (a change file may still reference a blob the snapshot does not carry).
  /// Returns the number of deleted blobs; failures are reported per blob and
  /// never abort the sweep.
  Future<int> deleteUnreferenced(Iterable<String> referencedSha256) async {
    final referenced = referencedSha256.toSet();
    var deleted = 0;
    final List<String> blobs;
    try {
      blobs = await transport.listBlobs(localDeviceId);
    } on SyncTransportException {
      return 0;
    }
    for (final sha in blobs) {
      if (referenced.contains(sha)) continue;
      try {
        await transport.deleteBlob(localDeviceId, sha);
        deleted++;
      } on SyncTransportException {
        // Keep sweeping; the blob stays for the next run.
      }
    }
    return deleted;
  }
}
