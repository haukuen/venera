/// Canonical, unambiguous composite keys for synced records.
///
/// Keys are encoded as compact JSON arrays. Segment values may contain any
/// character (`/`, `@`, `#`, `"`, `\`, unicode, ...), so callers must never
/// split a key by separators.
library;

import 'dart:convert';

class SyncKey implements Comparable<SyncKey> {
  SyncKey(List<String> parts) : parts = List.unmodifiable(parts) {
    _validate(this.parts);
  }

  /// The decoded segments of this key.
  final List<String> parts;

  static const int maxParts = 8;
  static const int maxEncodedBytes = 4096;

  /// Maximum allowed length (UTF-8 bytes) of a single segment.
  static const int maxSegmentBytes = 2048;

  static SyncKey of(List<String> parts) => SyncKey(parts);

  /// Encodes the key as a compact JSON array.
  String encode() => jsonEncode(parts);

  static SyncKey decode(String encoded) {
    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException catch (error) {
      throw FormatException('Invalid sync key: $error', encoded);
    }
    if (decoded is! List || decoded.any((part) => part is! String)) {
      throw FormatException(
        'Invalid sync key, expected a JSON string array',
        encoded,
      );
    }
    return SyncKey(decoded.cast<String>());
  }

  static void _validate(List<String> parts) {
    if (parts.isEmpty) {
      throw ArgumentError('Sync key must have at least one segment');
    }
    if (parts.length > maxParts) {
      throw ArgumentError('Sync key has too many segments: ${parts.length}');
    }
    var totalBytes = 2; // "[" + "]"
    for (final part in parts) {
      final bytes = utf8.encode(part).length;
      if (bytes > maxSegmentBytes) {
        throw ArgumentError('Sync key segment too long: $bytes bytes');
      }
      totalBytes += bytes + 3; // quotes + comma (over-approximation)
    }
    if (totalBytes > maxEncodedBytes) {
      throw ArgumentError('Sync key too long: $totalBytes bytes');
    }
  }

  @override
  int compareTo(SyncKey other) => encode().compareTo(other.encode());

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SyncKey || other.parts.length != parts.length) return false;
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] != other.parts[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => encode();
}
