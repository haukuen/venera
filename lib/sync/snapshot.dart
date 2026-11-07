/// Snapshot wire format.
///
/// A snapshot is a gzip-compressed JSONL file:
/// first line = [SnapshotInfo] with `"snapshot": true`,
/// then optional `{"t":"clear", ...}` cutoff lines,
/// then `{"t":"reg", ...}` records (including tombstones).
///
/// Snapshots are complete per-device state views. Applying a snapshot only
/// updates records with newer versions and applies the tombstone/cutoff facts
/// it carries; it never deletes records merely because they are absent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'hlc.dart';
import 'key_codec.dart';
import 'op.dart';
import 'version.dart';

class SnapshotInfo {
  SnapshotInfo({
    this.protocol = syncProtocolVersion,
    this.schema = syncProtocolVersion,
    required this.deviceId,
    required this.hlc,
    required this.rangeLo,
    required this.rangeHi,
    required this.applied,
    required this.domains,
  }) {
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
    if (rangeLo <= 0 || rangeHi < rangeLo) {
      throw ArgumentError('Invalid snapshot range: $rangeLo-$rangeHi');
    }
    for (final entry in applied.entries) {
      if (!hlcDeviceIdRegExp.hasMatch(entry.key) || entry.value < 0) {
        throw ArgumentError('Invalid applied watermark for ${entry.key}');
      }
    }
    for (final domain in domains) {
      if (!syncDomainRegExp.hasMatch(domain)) {
        throw ArgumentError('Invalid snapshot domain: $domain');
      }
    }
  }

  final int protocol;
  final int schema;
  final String deviceId;
  final Hlc hlc;
  final int rangeLo;
  final int rangeHi;

  /// Watermarks covered by this snapshot: device -> contiguous seq.
  final Map<String, int> applied;

  /// Domains included in this snapshot. Domains not listed are untouched by
  /// the receiver (e.g. auth sync disabled on the producing device).
  final Set<String> domains;

  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'schema': schema,
    'dev': deviceId,
    'hlc': hlc.encoded,
    'range': [rangeLo, rangeHi],
    'applied': applied,
    'domains': domains.toList()..sort(),
  };

  static SnapshotInfo fromJson(Map<String, Object?> json) {
    final protocol = json['protocol'] ?? syncProtocolVersion;
    final schema = json['schema'] ?? protocol;
    final device = json['dev'];
    final hlc = json['hlc'];
    final range = json['range'];
    final applied = json['applied'];
    final domains = json['domains'];
    if (protocol is! int ||
        schema is! int ||
        device is! String ||
        hlc is! String ||
        range is! List ||
        range.length != 2 ||
        range[0] is! int ||
        range[1] is! int ||
        applied is! Map ||
        domains is! List ||
        domains.any((domain) => domain is! String)) {
      throw const FormatException('Invalid snapshot info');
    }
    return SnapshotInfo(
      protocol: protocol,
      schema: schema,
      deviceId: device,
      hlc: Hlc.parse(hlc),
      rangeLo: range[0] as int,
      rangeHi: range[1] as int,
      applied: applied.map(
        (key, value) => MapEntry(key.toString(), value as int),
      ),
      domains: domains.cast<String>().toSet(),
    );
  }

  SnapshotInfo copyWith({
    int? protocol,
    int? schema,
    String? deviceId,
    Hlc? hlc,
    int? rangeLo,
    int? rangeHi,
    Map<String, int>? applied,
    Set<String>? domains,
  }) => SnapshotInfo(
    protocol: protocol ?? this.protocol,
    schema: schema ?? this.schema,
    deviceId: deviceId ?? this.deviceId,
    hlc: hlc ?? this.hlc,
    rangeLo: rangeLo ?? this.rangeLo,
    rangeHi: rangeHi ?? this.rangeHi,
    applied: applied ?? this.applied,
    domains: domains ?? this.domains,
  );

  @override
  String toString() =>
      'SnapshotInfo($deviceId seq $rangeLo-$rangeHi @${hlc.encoded})';
}

class SnapshotRecord {
  SnapshotRecord({
    required this.domain,
    required this.key,
    required this.field,
    required this.version,
    this.deletedVersion,
    this.data,
  }) {
    if (!syncDomainRegExp.hasMatch(domain)) {
      throw ArgumentError.value(domain, 'domain', 'Invalid domain');
    }
    if (!syncFieldRegExp.hasMatch(field)) {
      throw ArgumentError.value(field, 'field', 'Invalid field');
    }
  }

  final String domain;
  final SyncKey key;
  final String field;

  /// Latest known live version (also kept for tombstones).
  final Version version;

  /// Latest remove/delete version, if the record is a tombstone.
  final Version? deletedVersion;

  /// JSON payload for live register records; `null` for set members and
  /// tombstones.
  final Map<String, Object?>? data;

  bool get visible =>
      deletedVersion == null ? data != null : version > deletedVersion!;

  Map<String, Object?> toJson() => {
    't': 'reg',
    'd': domain,
    'k': key.parts,
    'f': field,
    'hlc': version.hlc.encoded,
    'seq': version.seq,
    if (deletedVersion != null) 'deletedHlc': deletedVersion!.hlc.encoded,
    if (deletedVersion != null) 'deletedSeq': deletedVersion!.seq,
    if (data != null) 'data': data,
  };

  static SnapshotRecord fromJson(Map<String, Object?> json) {
    final domain = json['d'];
    final rawKey = json['k'];
    final field = json['f'] ?? '';
    final hlc = json['hlc'];
    final seq = json['seq'];
    if (domain is! String ||
        rawKey is! List ||
        rawKey.any((part) => part is! String) ||
        field is! String ||
        hlc is! String ||
        seq is! int) {
      throw const FormatException('Invalid snapshot record');
    }
    Version? deletedVersion;
    final deletedHlc = json['deletedHlc'];
    final deletedSeq = json['deletedSeq'];
    if (deletedHlc != null || deletedSeq != null) {
      if (deletedHlc is! String || deletedSeq is! int) {
        throw const FormatException('Invalid snapshot tombstone');
      }
      deletedVersion = Version(Hlc.parse(deletedHlc), deletedSeq);
    }
    final rawData = json['data'];
    Map<String, Object?>? data;
    if (rawData != null) {
      if (rawData is! Map) {
        throw const FormatException('Invalid snapshot record data');
      }
      data = rawData.map((key, value) => MapEntry(key.toString(), value));
    }
    return SnapshotRecord(
      domain: domain,
      key: SyncKey(rawKey.cast<String>()),
      field: field,
      version: Version(Hlc.parse(hlc), seq),
      deletedVersion: deletedVersion,
      data: data,
    );
  }
}

class ParsedSnapshot {
  ParsedSnapshot({
    required this.info,
    required this.clears,
    required this.records,
  });

  final SnapshotInfo info;
  final Map<String, Version> clears;
  final List<SnapshotRecord> records;
}

class SnapshotCodec {
  static const int maxCompressedBytes = 16 << 20;
  static const int maxDecompressedBytes = 64 << 20;
  static const int maxRecords = 200000;

  static final GZipCodec _gzip = GZipCodec();

  static Uint8List encode(
    SnapshotInfo info,
    Map<String, Version> clears,
    Iterable<SnapshotRecord> records,
  ) {
    final buffer = StringBuffer();
    final infoJson = info.toJson()..['snapshot'] = true;
    buffer.write(jsonEncode(infoJson));
    for (final entry in clears.entries) {
      buffer
        ..write('\n')
        ..write(
          jsonEncode({
            't': 'clear',
            'd': entry.key,
            'cutoffHlc': entry.value.hlc.encoded,
            'cutoffSeq': entry.value.seq,
          }),
        );
    }
    var count = 0;
    for (final record in records) {
      count++;
      if (count > maxRecords) {
        throw ArgumentError('Too many records in snapshot');
      }
      buffer
        ..write('\n')
        ..write(jsonEncode(record.toJson()));
    }
    final raw = utf8.encode(buffer.toString());
    if (raw.length > maxDecompressedBytes) {
      throw ArgumentError('Uncompressed snapshot too large');
    }
    final compressed = _gzip.encode(raw);
    if (compressed.length > maxCompressedBytes) {
      throw ArgumentError('Compressed snapshot too large');
    }
    return Uint8List.fromList(compressed);
  }

  static ParsedSnapshot decode(Uint8List bytes, {String? expectedDeviceId}) {
    final raw = _gunzip(bytes);
    final text = utf8.decode(raw);
    final lines = text.split('\n').where((line) => line.trim().isNotEmpty);
    SnapshotInfo? info;
    final clears = <String, Version>{};
    final records = <SnapshotRecord>[];
    for (final line in lines) {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('Invalid snapshot line');
      }
      final json = decoded.cast<String, Object?>();
      if (info == null) {
        if (json['snapshot'] != true) {
          throw const FormatException('Missing snapshot meta line');
        }
        info = SnapshotInfo.fromJson(json);
        if (expectedDeviceId != null && info.deviceId != expectedDeviceId) {
          throw FormatException(
            'Snapshot device mismatch: ${info.deviceId} != $expectedDeviceId',
          );
        }
        continue;
      }
      final type = json['t'];
      if (type == 'clear') {
        final domain = json['d'];
        final cutoffHlc = json['cutoffHlc'];
        final cutoffSeq = json['cutoffSeq'];
        if (domain is! String ||
            !syncDomainRegExp.hasMatch(domain) ||
            cutoffHlc is! String ||
            cutoffSeq is! int) {
          throw const FormatException('Invalid snapshot clear');
        }
        // Same coverage contract as records below: an undeclared domain
        // claims authority over data the snapshot does not carry, which would
        // silently hide newer records behind its cutoff.
        if (!info.domains.contains(domain)) {
          throw const FormatException(
            'Snapshot contains a clear for a domain it does not declare',
          );
        }
        final version = Version(Hlc.parse(cutoffHlc), cutoffSeq);
        if (version.seq <= 0) {
          throw const FormatException('Invalid snapshot clear seq');
        }
        final existing = clears[domain];
        if (existing == null || version > existing) clears[domain] = version;
      } else if (type == 'reg') {
        final record = SnapshotRecord.fromJson(json);
        if (record.version.seq <= 0) {
          throw const FormatException('Invalid snapshot record seq');
        }
        final deleted = record.deletedVersion;
        if (deleted != null && deleted.seq <= 0) {
          throw const FormatException('Invalid snapshot record delete seq');
        }
        records.add(record);
        if (records.length > maxRecords) {
          throw const FormatException('Too many snapshot records');
        }
      }
      // Unknown line types are ignored for forward compatibility.
    }
    if (info == null) {
      throw const FormatException('Empty snapshot');
    }
    if (records.any((record) => !info!.domains.contains(record.domain))) {
      throw const FormatException(
        'Snapshot contains a record for a domain it does not declare',
      );
    }
    return ParsedSnapshot(info: info, clears: clears, records: records);
  }

  /// [encode] off the calling isolate. Snapshots reach megabytes, so the
  /// JSON encode + gzip always run outside the UI isolate.
  ///
  /// [records] is materialized on the caller side first: only concrete
  /// sendable objects may cross the isolate boundary, and a lazy iterable
  /// would fail [Isolate.run].
  static Future<Uint8List> encodeAsync(
    SnapshotInfo info,
    Map<String, Version> clears,
    Iterable<SnapshotRecord> records,
  ) {
    final snapshotRecords = List<SnapshotRecord>.of(records);
    return Isolate.run(() => encode(info, clears, snapshotRecords));
  }

  /// [decode] off the calling isolate; see [encodeAsync].
  static Future<ParsedSnapshot> decodeAsync(
    Uint8List bytes, {
    String? expectedDeviceId,
  }) => Isolate.run(() => decode(bytes, expectedDeviceId: expectedDeviceId));

  static Uint8List _gunzip(Uint8List bytes) {
    if (bytes.length > maxCompressedBytes) {
      throw FormatException('Compressed snapshot too large: ${bytes.length}');
    }
    final sink = _LimitedByteSink(maxDecompressedBytes);
    final decoder = _gzip.decoder.startChunkedConversion(sink);
    decoder.add(bytes);
    decoder.close();
    return sink.takeBytes();
  }
}

class _LimitedByteSink implements Sink<List<int>> {
  _LimitedByteSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  var _length = 0;

  @override
  void add(List<int> data) {
    _length += data.length;
    if (_length > limit) {
      throw FormatException('Decompressed data exceeds $limit bytes');
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
