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
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hlc.dart';
import 'transport.dart';

class BlobSync {
  BlobSync({required this.transport, required this.localDeviceId}) {
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

  static final RegExp sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// sha256 of the uncompressed blob content, as referenced by records.
  static String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

  static void validateSha256(String sha256) {
    if (!sha256Pattern.hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'Invalid sha256');
    }
  }

  /// Uploads [bytes] to this device's branch when it is not already present.
  ///
  /// Returns the sha256 reference to store in a record payload. Existing blobs
  /// are verified when [verifyExisting] is true, so a corrupted remote copy is
  /// rejected instead of silently accepted.
  Future<String> upload(Uint8List bytes, {bool verifyExisting = true}) async {
    final sha = sha256Hex(bytes);
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
      return sha;
    }
    await transport.writeBlob(localDeviceId, sha, bytes);
    return sha;
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
