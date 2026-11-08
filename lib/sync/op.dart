/// Wire format for sync operations.
///
/// A change file is a gzip-compressed JSONL stream where every line is one
/// [SyncOp]. The file covers a contiguous per-device sequence range
/// `[lo, hi]`; the device id and the range are part of the file name and are
/// validated on decode.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'hlc.dart';
import 'key_codec.dart';
import 'version.dart';

const int syncProtocolVersion = 2;

/// Domain names are fixed enum-like identifiers, e.g. `history`,
/// `favoriteComic`, `readLater`, `setting`, `auth`.
final RegExp syncDomainRegExp = RegExp(r'^[a-zA-Z][a-zA-Z0-9_.-]{0,31}$');

/// Field group names are either empty (the record itself) or a short
/// identifier, e.g. `progress` / `meta`.
final RegExp syncFieldRegExp = RegExp(r'^([a-zA-Z][a-zA-Z0-9_.-]{0,31})?$');

enum SyncOpKind {
  /// Upsert a register / metadata record.
  upsert,

  /// Add an element to a set-like domain.
  add,

  /// Remove an element from a set-like domain (tombstone).
  del,

  /// Domain-wide cutoff clear.
  clear;

  static SyncOpKind parse(String value) {
    for (final kind in SyncOpKind.values) {
      if (kind.name == value) return kind;
    }
    throw FormatException('Unknown sync op kind', value);
  }
}

/// One immutable sync operation.
class SyncOp {
  SyncOp({
    required this.deviceId,
    required this.seq,
    required this.version,
    required this.domain,
    required this.field,
    required this.kind,
    this.key,
    this.data,
  }) {
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
    if (version.hlc.deviceId != deviceId) {
      throw ArgumentError('HLC device must match op device');
    }
    if (seq <= 0) {
      throw ArgumentError.value(seq, 'seq', 'seq must be positive');
    }
    if (!syncDomainRegExp.hasMatch(domain)) {
      throw ArgumentError.value(domain, 'domain', 'Invalid domain');
    }
    if (!syncFieldRegExp.hasMatch(field)) {
      throw ArgumentError.value(field, 'field', 'Invalid field group');
    }
    if (kind == SyncOpKind.clear) {
      if (key != null) {
        throw ArgumentError('Clear ops must not carry a key');
      }
      if (field.isNotEmpty) {
        throw ArgumentError('Clear ops must use an empty field group');
      }
      if (data != null) {
        throw ArgumentError('Clear ops must not carry data');
      }
    } else if (key == null) {
      throw ArgumentError('Non-clear ops must carry a key');
    }
  }

  final String deviceId;
  final int seq;
  final Version version;
  final String domain;
  final SyncKey? key;
  final String field;
  final SyncOpKind kind;

  /// JSON-serializable payload. `null` for `del` and `clear` ops.
  final Map<String, Object?>? data;

  bool get isClear => kind == SyncOpKind.clear;

  bool get isSetLike => kind == SyncOpKind.add || kind == SyncOpKind.del;

  Map<String, Object?> toJson() => {
    'v': syncProtocolVersion,
    'dev': deviceId,
    'seq': seq,
    'hlc': version.hlc.encoded,
    'd': domain,
    'k': key == null ? '*' : key!.parts,
    'f': field,
    'op': kind.name,
    if (data != null) 'data': data,
  };

  static SyncOp fromJson(Map<String, Object?> json) {
    final protocol = json['v'];
    if (protocol is! int || protocol != syncProtocolVersion) {
      throw FormatException('Unsupported sync protocol version', protocol);
    }
    final deviceId = json['dev'];
    final seq = json['seq'];
    final hlc = json['hlc'];
    final domain = json['d'];
    final field = json['f'] ?? '';
    final kindText = json['op'];
    if (deviceId is! String ||
        seq is! int ||
        hlc is! String ||
        domain is! String ||
        field is! String ||
        kindText is! String) {
      throw FormatException('Invalid sync op json');
    }
    final kind = SyncOpKind.parse(kindText);

    SyncKey? key;
    if (kind != SyncOpKind.clear) {
      final wireKey = json['k'];
      if (wireKey is! List || wireKey.any((part) => part is! String)) {
        throw FormatException('Invalid sync op key');
      }
      key = SyncKey(wireKey.cast<String>());
    }

    final rawData = json['data'];
    Map<String, Object?>? data;
    if (rawData != null) {
      if (rawData is! Map) {
        throw const FormatException('Invalid sync op data');
      }
      data = rawData.map((key, value) => MapEntry(key.toString(), value));
    }

    return SyncOp(
      deviceId: deviceId,
      seq: seq,
      version: Version(Hlc.parse(hlc), seq),
      domain: domain,
      key: key,
      field: field,
      kind: kind,
      data: data,
    );
  }

  @override
  String toString() =>
      'SyncOp($deviceId#$seq ${kind.name} $domain ${key ?? '*'} $field)';
}

/// Codec for change files (JSONL + gzip).
class SyncOpCodec {
  static const int maxOpsPerBatch = 2000;
  static const int maxCompressedBytes = 2 << 20;
  static const int maxDecompressedBytes = 8 << 20;
  static const int maxOpPayloadBytes = 1 << 20;

  static final GZipCodec _gzip = GZipCodec();

  /// Encodes [ops] into a gzip-compressed JSONL byte buffer.
  ///
  /// [ops] must be non-empty and ordered by ascending `seq`.
  static Uint8List encode(List<SyncOp> ops) {
    if (ops.isEmpty) {
      throw ArgumentError('Cannot encode an empty op batch');
    }
    if (ops.length > maxOpsPerBatch) {
      throw ArgumentError('Too many ops in one change file: ${ops.length}');
    }
    final buffer = StringBuffer();
    for (var i = 0; i < ops.length; i++) {
      if (i > 0) {
        if (ops[i].seq != ops[i - 1].seq + 1) {
          throw ArgumentError('Op batch is not contiguous at index $i');
        }
        buffer.write('\n');
      }
      final line = jsonEncode(ops[i].toJson());
      if (line.length > maxOpPayloadBytes) {
        throw ArgumentError('Sync op payload too large');
      }
      buffer.write(line);
    }
    final raw = utf8.encode(buffer.toString());
    if (raw.length > maxDecompressedBytes) {
      throw ArgumentError('Uncompressed change file too large');
    }
    final compressed = _gzip.encode(raw);
    if (compressed.length > maxCompressedBytes) {
      throw ArgumentError('Compressed change file too large');
    }
    return Uint8List.fromList(compressed);
  }

  /// Decodes and validates a change file.
  ///
  /// The caller passes the expected device id and contiguous sequence range
  /// derived from the file name. Any mismatch raises [FormatException] so the
  /// engine can treat the file as a gap and repair it via snapshot.
  static List<SyncOp> decode(
    Uint8List bytes, {
    required String expectedDeviceId,
    required int lo,
    required int hi,
  }) {
    final raw = _gunzip(bytes);
    final text = utf8.decode(raw);
    final lines = text.split('\n').where((line) => line.trim().isNotEmpty);
    final ops = <SyncOp>[];
    for (final line in lines) {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('Invalid sync op line');
      }
      final op = SyncOp.fromJson(decoded.cast<String, Object?>());
      if (op.deviceId != expectedDeviceId) {
        throw FormatException(
          'Change file device mismatch: ${op.deviceId} != $expectedDeviceId',
        );
      }
      if (ops.isNotEmpty && op.seq != ops.last.seq + 1) {
        throw FormatException('Change file sequence hole at ${op.seq}');
      }
      ops.add(op);
    }
    if (ops.isEmpty) {
      throw const FormatException('Empty change file');
    }
    if (ops.length > maxOpsPerBatch) {
      throw FormatException('Too many ops in change file: ${ops.length}');
    }
    if (ops.first.seq != lo || ops.last.seq != hi) {
      throw FormatException(
        'Change file range mismatch: got ${ops.first.seq}-${ops.last.seq}, '
        'expected $lo-$hi',
      );
    }
    return ops;
  }

  /// Decodes only the first line (cheap metadata probes).
  static Map<String, Object?> decodeFirstLine(Uint8List bytes) {
    final raw = _gunzip(bytes);
    final text = utf8.decode(raw);
    final newline = text.indexOf('\n');
    final line = newline == -1 ? text : text.substring(0, newline);
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const FormatException('Invalid first line');
    }
    return decoded.cast<String, Object?>();
  }

  static const int _isolateEncodeOps = 256;
  static const int _isolateDecodeBytes = 64 * 1024;

  /// [encode] off the calling isolate for large batches. Small batches stay
  /// inline: spawning an isolate costs more than gzipping a few ops, and the
  /// engine pushes one-op change files while the user is reading.
  static Future<Uint8List> encodeAsync(List<SyncOp> ops) {
    if (ops.length < _isolateEncodeOps) return Future.value(encode(ops));
    return Isolate.run(() => encode(ops));
  }

  /// [decode] off the calling isolate for large change files. The engine
  /// pulls many small files per pass, so the size gate matters here.
  static Future<List<SyncOp>> decodeAsync(
    Uint8List bytes, {
    required String expectedDeviceId,
    required int lo,
    required int hi,
  }) {
    if (bytes.length < _isolateDecodeBytes) {
      return Future.value(
        decode(bytes, expectedDeviceId: expectedDeviceId, lo: lo, hi: hi),
      );
    }
    return Isolate.run(
      () => decode(bytes, expectedDeviceId: expectedDeviceId, lo: lo, hi: hi),
    );
  }

  static Uint8List _gunzip(Uint8List bytes) {
    if (bytes.length > maxCompressedBytes) {
      throw FormatException(
        'Compressed change file too large: ${bytes.length}',
      );
    }
    final sink = _LimitedByteSink(maxDecompressedBytes);
    final decoder = _gzip.decoder.startChunkedConversion(sink);
    decoder.add(bytes);
    decoder.close();
    return sink.takeBytes();
  }
}

/// Collects decompressed bytes while enforcing a hard size limit, so a
/// malicious gzip payload cannot exhaust memory.
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
