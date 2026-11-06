/// Transport contract between the sync engine and a storage backend
/// (WebDAV, in-memory fake, ...).
///
/// All methods must be safe to retry: writing the same content again is
/// idempotent from the protocol's point of view.
library;

import 'dart:typed_data';

import 'hlc.dart';
import 'snapshot.dart';

class RemoteDeviceInfo {
  const RemoteDeviceInfo({required this.deviceId, this.name, this.lastSeen});

  final String deviceId;
  final String? name;
  final DateTime? lastSeen;
}

class ChangeRange {
  const ChangeRange({
    required this.lo,
    required this.hi,
    this.etag,
    this.modified,
  });

  final int lo;
  final int hi;
  final String? etag;
  final DateTime? modified;

  @override
  String toString() => 'ChangeRange($lo-$hi)';
}

/// The small per-device status document stored as `devices/<id>.json`.
class RemoteState {
  RemoteState({
    this.protocol = 2,
    required this.deviceId,
    required this.updatedHlc,
    required this.lastChange,
    required this.applied,
    this.snapshot,
    this.lastSeen,
  }) {
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
    if (lastChange < 0) {
      throw ArgumentError.value(lastChange, 'lastChange', 'Must be >= 0');
    }
  }

  final int protocol;
  final String deviceId;
  final Hlc updatedHlc;

  /// Highest change-file seq this device has uploaded to the remote.
  final int lastChange;

  /// Local merge watermarks, device -> contiguous seq.
  final Map<String, int> applied;

  /// Metadata of the latest snapshot uploaded by this device, if any.
  final SnapshotInfo? snapshot;

  final DateTime? lastSeen;

  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'device': deviceId,
    'updatedHlc': updatedHlc.encoded,
    'lastChange': lastChange,
    'applied': applied,
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
    if (lastSeen != null) 'lastSeen': lastSeen!.toUtc().toIso8601String(),
  };

  static RemoteState fromJson(Map<String, Object?> json) {
    final protocol = json['protocol'] ?? 2;
    final device = json['device'];
    final updatedHlc = json['updatedHlc'];
    final lastChange = json['lastChange'];
    final applied = json['applied'];
    if (protocol is! int ||
        device is! String ||
        updatedHlc is! String ||
        lastChange is! int ||
        applied is! Map) {
      throw const FormatException('Invalid remote state');
    }
    SnapshotInfo? snapshot;
    final rawSnapshot = json['snapshot'];
    if (rawSnapshot != null) {
      if (rawSnapshot is! Map) {
        throw const FormatException('Invalid remote snapshot info');
      }
      snapshot = SnapshotInfo.fromJson(
        rawSnapshot.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    final rawLastSeen = json['lastSeen'];
    DateTime? lastSeen;
    if (rawLastSeen is String) {
      lastSeen = DateTime.tryParse(rawLastSeen);
    }
    return RemoteState(
      protocol: protocol,
      deviceId: device,
      updatedHlc: Hlc.parse(updatedHlc),
      lastChange: lastChange,
      applied: applied.map(
        (key, value) => MapEntry(key.toString(), value as int),
      ),
      snapshot: snapshot,
      lastSeen: lastSeen,
    );
  }

  RemoteState copyWith({
    int? protocol,
    String? deviceId,
    Hlc? updatedHlc,
    int? lastChange,
    Map<String, int>? applied,
    SnapshotInfo? snapshot,
    DateTime? lastSeen,
  }) => RemoteState(
    protocol: protocol ?? this.protocol,
    deviceId: deviceId ?? this.deviceId,
    updatedHlc: updatedHlc ?? this.updatedHlc,
    lastChange: lastChange ?? this.lastChange,
    applied: applied ?? this.applied,
    snapshot: snapshot ?? this.snapshot,
    lastSeen: lastSeen ?? this.lastSeen,
  );

  @override
  String toString() =>
      'RemoteState($deviceId lastChange=$lastChange applied=$applied)';
}

class SyncTransportException implements Exception {
  SyncTransportException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'SyncTransportException($message${statusCode == null ? '' : ', $statusCode'})';
}

abstract class SyncTransport {
  /// Lists remote device directories / state files.
  Future<List<RemoteDeviceInfo>> listDevices();

  /// Reads one device's state file, or `null` when it does not exist.
  Future<RemoteState?> readState(String deviceId);

  /// Lists uploaded change ranges of a device, sorted ascending.
  Future<List<ChangeRange>> listChanges(String deviceId);

  /// Reads a change file. Must return `null` when absent.
  Future<Uint8List?> readChanges(String deviceId, ChangeRange range);

  /// Reads the current snapshot of a device, or `null` when absent.
  Future<Uint8List?> readSnapshot(String deviceId);

  /// Reads the metadata (first line) of a device's snapshot.
  Future<SnapshotInfo?> readSnapshotInfo(String deviceId);

  /// Writes a change file with contiguous range `[lo, hi]`.
  Future<void> writeChanges(String deviceId, int lo, int hi, Uint8List bytes);

  /// Writes the small status document of a device.
  Future<void> writeState(String deviceId, RemoteState state);

  /// Writes the snapshot of a device.
  Future<void> writeSnapshot(String deviceId, Uint8List bytes);

  /// Writes a content-addressed blob (immutable).
  Future<void> writeBlob(String deviceId, String sha256, Uint8List bytes);

  /// Reads a content-addressed blob, or `null` when absent.
  Future<Uint8List?> readBlob(String deviceId, String sha256);

  /// Lists the sha256 names of a device's uploaded blobs.
  Future<List<String>> listBlobs(String deviceId);

  /// Deletes a content-addressed blob; missing blobs are ignored.
  Future<void> deleteBlob(String deviceId, String sha256);

  /// Deletes change files up to and including [upToSeq].
  Future<void> deleteChanges(String deviceId, int upToSeq);

  /// Deletes all remote data of a device (device management).
  Future<void> deleteDevice(String deviceId);

  /// Creates or validates the shared schema document.
  Future<void> ensureSchema(Uint8List schemaJson);

  Future<void> close();
}
