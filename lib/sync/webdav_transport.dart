/// WebDAV-backed [SyncTransport] for the Venera v2 sync protocol.
///
/// Remote layout (protocol doc §2), relative to the configured WebDAV
/// directory:
///
/// ```text
/// v2/devices/<deviceId>.json
/// v2/devices/<deviceId>/device.json
/// v2/devices/<deviceId>/snapshot.jsonl.gz
/// v2/devices/<deviceId>/snapshot.prev.jsonl.gz
/// v2/devices/<deviceId>/changes/000000000001-000000000042.jsonl.gz
/// v2/devices/<deviceId>/blobs/<sha256>.gz
/// ```
///
/// Security notes (protocol doc §12.3): every value that ends up in a remote
/// path segment is validated and URI-encoded before being joined, and remote
/// names are never trusted for local paths — they are only matched against
/// strict regular expressions.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart'
    show DioException, Options, Response, ResponseType;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart' show RHttpAdapter;
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'hlc.dart';
import 'snapshot.dart';
import 'transport.dart';

/// Creates a `package:webdav_client` client for [baseUrl].
///
/// Injected in tests to keep path/state tests entirely offline. The real
/// production factory wraps the client with the app's `RHttpAdapter`.
typedef WebDavClientFactory =
    webdav.Client Function(String baseUrl, String user, String password);

webdav.Client _defaultWebDavClientFactory(
  String baseUrl,
  String user,
  String password,
) {
  return webdav.newClient(
    baseUrl,
    user: user,
    password: password,
    adapter: RHttpAdapter(
      enableProxy: appdata.settings['webdavProxyEnabled'] != false,
    ),
  );
}

/// One entry of a WebDAV directory listing.
class WebDavEntry {
  const WebDavEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.etag,
    this.modified,
  });

  /// Decoded entry name (the last path segment), as reported by the server.
  final String name;

  /// Server-reported path (informational only; never used locally).
  final String path;

  final bool isDirectory;
  final String? etag;
  final DateTime? modified;

  @override
  String toString() => 'WebDavEntry($name, dir=$isDirectory, etag=$etag)';
}

/// Result of a WebDAV `MOVE`.
enum WebDavMoveResult {
  /// The move succeeded (including overwriting the destination).
  moved,

  /// The server rejected the source with 404.
  notFound,

  /// The server does not implement `MOVE` (405/501).
  unsupported,
}

/// Narrow WebDAV operations surface used by [WebDavSyncTransport].
///
/// The interface exists so tests can substitute an in-memory implementation
/// and so the transport contains no HTTP details. Paths are already encoded
/// (see [WebDavPaths]) and are relative to the configured WebDAV directory.
abstract class WebDavIo {
  /// Lists children of a collection, `null` when the collection is absent.
  Future<List<WebDavEntry>?> list(String path);

  /// Reads a file, `null` when absent.
  Future<Uint8List?> read(String path);

  /// Reads at most [maxLength] leading bytes of a file, `null` when absent.
  ///
  /// Implemented with a Range request when the server supports it, falling
  /// back to a full GET. Used for cheap metadata probes of large files.
  Future<Uint8List?> readHead(String path, int maxLength);

  /// Writes a file (creating missing parent collections), overwriting any
  /// previous content. Retrying the same content is idempotent.
  Future<void> write(String path, Uint8List bytes);

  /// Moves [from] to [to], overwriting [to].
  Future<WebDavMoveResult> move(String from, String to);

  /// Deletes a file; missing files are ignored.
  Future<void> remove(String path);

  /// Deletes a collection recursively; missing collections are ignored.
  Future<void> removeDirectory(String path);

  Future<void> close();
}

/// Implementation of [WebDavIo] over `package:webdav_client`.
///
/// Uses the low level request entry point of the (pinned) fork for reads and
/// writes because it exposes raw HTTP status codes (needed for
/// "404 means absent" and `If-None-Match: *` handling) and avoids the extra
/// `OPTIONS` preflight that the high level helpers perform.
class PackageWebDavIo implements WebDavIo {
  PackageWebDavIo(this.client);

  final webdav.Client client;

  final Set<String> _ensuredParents = {};

  @override
  Future<List<WebDavEntry>?> list(String path) async {
    try {
      final files = await client.readDir(path);
      return [
        for (final file in files)
          WebDavEntry(
            name: file.name ?? '',
            path: file.path ?? '',
            isDirectory: file.isDir == true,
            etag: (file.eTag == null || file.eTag!.isEmpty) ? null : file.eTag,
            modified: file.mTime,
          ),
      ];
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Uint8List?> read(String path) async {
    final response = await _request(
      'GET',
      path,
      optionsHandler: (options) {
        options.responseType = ResponseType.bytes;
      },
    );
    return _bytesOrNull(path, response);
  }

  @override
  Future<Uint8List?> readHead(String path, int maxLength) async {
    Future<Response<dynamic>> get([Map<String, String>? headers]) {
      return _request(
        'GET',
        path,
        optionsHandler: (options) {
          options.responseType = ResponseType.bytes;
          if (headers != null) options.headers!.addAll(headers);
        },
      );
    }

    // Try a range request first; a server without range support answers 200
    // with the whole body, which is still correct (just less efficient).
    final ranged = await get({'range': 'bytes=0-${maxLength - 1}'});
    final status = ranged.statusCode;
    if (status == 206) {
      final data = ranged.data;
      if (data is Uint8List) return data;
      if (data is List<int>) return Uint8List.fromList(data);
      if (data is String) return Uint8List.fromList(utf8.encode(data));
      throw SyncTransportException(
        'Unexpected 206 response body type: ${data.runtimeType}',
        statusCode: status,
      );
    }
    if (status == 404) return null;
    if (status != 200) {
      throw SyncTransportException('GET $path failed', statusCode: status);
    }
    final full = _bytesOrNull(path, ranged);
    if (full == null) return null;
    return full.length <= maxLength
        ? full
        : Uint8List.sublistView(full, 0, maxLength);
  }

  Uint8List? _bytesOrNull(String path, Response<dynamic> response) {
    final status = response.statusCode;
    if (status == 200) {
      final data = response.data;
      if (data is Uint8List) return data;
      if (data is List<int>) return Uint8List.fromList(data);
      if (data is String) return Uint8List.fromList(utf8.encode(data));
      if (data == null) return Uint8List(0);
      throw SyncTransportException(
        'Unexpected GET response body type: ${data.runtimeType}',
        statusCode: status,
      );
    }
    if (status == 404) return null;
    throw SyncTransportException('GET $path failed', statusCode: status);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    await _ensureParent(path);
    var response = await _put(path, bytes);
    if (response.statusCode == 409) {
      _ensuredParents.clear();
      await _ensureParent(path);
      response = await _put(path, bytes);
    }
    _checkWriteStatus('PUT', path, response.statusCode);
  }

  @override
  Future<WebDavMoveResult> move(String from, String to) async {
    var response = await _moveRequest(from, to);
    var status = response.statusCode;
    if (status == 409) {
      final parent = _parentOf(to);
      if (parent != null) {
        _ensuredParents.remove(parent);
        await client.mkdirAll(parent);
      }
      response = await _moveRequest(from, to);
      status = response.statusCode;
    }
    if (status == 201 || status == 204 || status == 207) {
      return WebDavMoveResult.moved;
    }
    if (status == 404) return WebDavMoveResult.notFound;
    if (status == 405 || status == 501) return WebDavMoveResult.unsupported;
    throw SyncTransportException(
      'MOVE $from -> $to failed',
      statusCode: status,
    );
  }

  @override
  Future<void> remove(String path) async {
    final response = await _request('DELETE', path);
    _checkDeleteStatus(path, response.statusCode);
  }

  @override
  Future<void> removeDirectory(String path) async {
    final trimmed = path.replaceFirst(RegExp(r'/+$'), '');
    var response = await _request('DELETE', '$trimmed/');
    var status = response.statusCode;
    if (status == 405) {
      // Some servers only accept a collection DELETE without the trailing
      // slash (and vice versa); retry once with the other spelling.
      response = await _request('DELETE', trimmed);
      status = response.statusCode;
    }
    _checkDeleteStatus(path, status);
  }

  @override
  Future<void> close() async {
    client.c.close(force: true);
  }

  Future<Response<dynamic>> _request(
    String method,
    String path, {
    Uint8List? body,
    void Function(Options options)? optionsHandler,
  }) {
    return client.c.req<dynamic>(
      client,
      method,
      path,
      data: body,
      optionsHandler: (options) {
        options.headers ??= <String, dynamic>{};
        if (body != null) {
          options.headers!['content-type'] = 'application/octet-stream';
        }
        optionsHandler?.call(options);
      },
    );
  }

  Future<Response<dynamic>> _put(
    String path,
    Uint8List bytes, {
    Map<String, String>? headers,
  }) {
    return _request(
      'PUT',
      path,
      body: bytes,
      optionsHandler: (options) {
        if (headers != null) options.headers!.addAll(headers);
      },
    );
  }

  Future<Response<dynamic>> _moveRequest(String from, String to) {
    // `client.uri` always ends with '/', so the destination is an absolute URL
    // with the already-encoded relative path appended.
    final destination = '${client.uri}$to';
    return _request(
      'MOVE',
      from,
      optionsHandler: (options) {
        options.headers!['destination'] = destination;
        options.headers!['overwrite'] = 'T';
      },
    );
  }

  Future<void> _ensureParent(String path) async {
    final parent = _parentOf(path);
    if (parent == null) return;
    if (!_ensuredParents.add(parent)) return;
    try {
      await client.mkdirAll(parent);
    } on Object {
      _ensuredParents.remove(parent);
      rethrow;
    }
  }

  static String? _parentOf(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return null;
    return path.substring(0, index);
  }

  static void _checkWriteStatus(String method, String path, int? status) {
    if (status == 200 || status == 201 || status == 204) return;
    throw SyncTransportException('$method $path failed', statusCode: status);
  }

  static void _checkDeleteStatus(String path, int? status) {
    if (status == 200 || status == 204 || status == 207 || status == 404) {
      return;
    }
    throw SyncTransportException('DELETE $path failed', statusCode: status);
  }
}

/// Builder for every remote path of the v2 layout.
///
/// Every path segment is validated (device id / sha256 / change range) and
/// percent-encoded before being joined, so a malicious server name or a device
/// id with separators can never escape the configured directory.
class WebDavPaths {
  WebDavPaths([String root = defaultRoot]) : root = _normalizeRoot(root);

  static const String defaultRoot = 'v2';

  static final RegExp changeFileNameRegExp = RegExp(
    r'^(\d{12})-(\d{12})\.jsonl\.gz$',
  );

  static final RegExp sha256RegExp = RegExp(r'^[0-9a-f]{64}$');

  /// Encoded path of the v2 root, relative to the configured WebDAV directory.
  final String root;

  static String _normalizeRoot(String root) {
    final segments = root
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .toList();
    if (segments.isEmpty) {
      throw ArgumentError.value(root, 'root', 'Must not be empty');
    }
    return segments.join('/');
  }

  static String encodeSegment(String value) => Uri.encodeComponent(value);

  String get devicesDir => '$root/devices';

  String statePath(String deviceId) =>
      '$devicesDir/${_deviceSegment(deviceId)}.json';

  String deviceDir(String deviceId) =>
      '$devicesDir/${_deviceSegment(deviceId)}';

  String deviceMetaPath(String deviceId) =>
      '${deviceDir(deviceId)}/device.json';

  String changesDir(String deviceId) => '${deviceDir(deviceId)}/changes';

  String changeFilePath(String deviceId, int lo, int hi) =>
      '${changesDir(deviceId)}/${changeFileName(lo, hi)}';

  String snapshotPath(String deviceId) =>
      '${deviceDir(deviceId)}/snapshot.jsonl.gz';

  String snapshotPrevPath(String deviceId) =>
      '${deviceDir(deviceId)}/snapshot.prev.jsonl.gz';

  String blobPath(String deviceId, String sha256) =>
      '${deviceDir(deviceId)}/blobs/${_shaSegment(sha256)}.gz';

  static String changeFileName(int lo, int hi) {
    if (lo <= 0) {
      throw ArgumentError.value(lo, 'lo', 'Change range lo must be positive');
    }
    if (hi < lo) {
      throw ArgumentError.value(hi, 'hi', 'Change range hi must be >= lo');
    }
    if (hi > 999999999999) {
      throw ArgumentError.value(hi, 'hi', 'Exceeds the 12-digit encoding');
    }
    return '${lo.toString().padLeft(12, '0')}-'
        '${hi.toString().padLeft(12, '0')}.jsonl.gz';
  }

  /// Parses `000000000001-000000000042.jsonl.gz`, returning `null` for
  /// anything that does not match the strict wire name.
  static ChangeRange? parseChangeFileName(String fileName) {
    final match = changeFileNameRegExp.firstMatch(fileName);
    if (match == null) return null;
    final lo = int.tryParse(match.group(1)!);
    final hi = int.tryParse(match.group(2)!);
    if (lo == null || hi == null) return null;
    if (lo <= 0 || hi < lo) return null;
    return ChangeRange(lo: lo, hi: hi);
  }

  static String _deviceSegment(String deviceId) {
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
    return Uri.encodeComponent(deviceId);
  }

  static String _shaSegment(String sha256) {
    if (!sha256RegExp.hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'Invalid sha256');
    }
    return Uri.encodeComponent(sha256);
  }
}

/// [SyncTransport] over WebDAV.
///
/// Use [WebDavSyncTransport.connect] in the app and
/// [WebDavSyncTransport.withIo] (or a [WebDavClientFactory]) in tests.
class WebDavSyncTransport implements SyncTransport {
  /// Connects to a WebDAV directory using the app's HTTP stack.
  factory WebDavSyncTransport.connect({
    required String baseUrl,
    String user = '',
    String password = '',
    WebDavClientFactory? clientFactory,
    String rootPath = WebDavPaths.defaultRoot,
  }) {
    final normalized = normalizeBaseUrl(baseUrl);
    final client = (clientFactory ?? _defaultWebDavClientFactory)(
      normalized,
      user,
      password,
    );
    return WebDavSyncTransport.withIo(
      PackageWebDavIo(client),
      rootPath: rootPath,
    );
  }

  /// Builds a transport on top of an injected [WebDavIo] (tests / simulation).
  WebDavSyncTransport.withIo(
    WebDavIo io, {
    String rootPath = WebDavPaths.defaultRoot,
  }) : _io = io,
       paths = WebDavPaths(rootPath);

  final WebDavIo _io;

  /// Path builder used for every remote request.
  final WebDavPaths paths;

  /// `null` while unknown, then whether `MOVE` works on this server.
  bool? _moveSupported;

  bool _closed = false;

  bool get isClosed => _closed;

  /// Validates a configured WebDAV directory URL.
  static String normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Invalid WebDAV URL');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Unsupported URL scheme');
    }
    // Re-serialize so characters that are illegal in a request URL or in the
    // MOVE `Destination` header (spaces, bare '%', non-ASCII) become
    // percent-encoded exactly once.
    return uri.toString();
  }

  // ------------------------------------------------------------- encoding --

  /// Encodes a [RemoteState] as the JSON body of `devices/<id>.json`.
  static Uint8List encodeRemoteState(RemoteState state) =>
      Uint8List.fromList(utf8.encode(jsonEncode(state.toJson())));

  /// Decodes `devices/<id>.json`.
  static RemoteState decodeRemoteState(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Remote state is not a JSON object');
    }
    return RemoteState.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  /// Decodes the meta line (first JSONL line) of a `snapshot.jsonl.gz`.
  ///
  /// [readSnapshotInfo] passes only a prefix of the gzip stream; inflate the
  /// leading bytes until the first newline of the *decompressed* data.
  static SnapshotInfo decodeSnapshotInfo(
    Uint8List bytes, {
    String? expectedDeviceId,
    bool prefixOnly = false,
  }) {
    final line = _decodeFirstLine(bytes, prefixOnly: prefixOnly);
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const FormatException('Invalid snapshot meta line');
    }
    final info = SnapshotInfo.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (expectedDeviceId != null && info.deviceId != expectedDeviceId) {
      throw FormatException(
        'Snapshot device mismatch: ${info.deviceId} != $expectedDeviceId',
      );
    }
    return info;
  }

  static const int _maxSnapshotMetaBytes = 256 << 10;

  /// Leading bytes fetched for a snapshot metadata probe. The gzip header
  /// (~18 bytes) plus one flate block of a JSON meta line stays well below
  /// this for realistic snapshot sizes.
  static const int _snapshotMetaProbeBytes = 4096;

  static String _decodeFirstLine(Uint8List bytes, {bool prefixOnly = false}) {
    if (bytes.isEmpty) throw const FormatException('Empty snapshot');
    final sink = _FirstLineSink(_maxSnapshotMetaBytes);
    final decoder = GZipCodec().decoder.startChunkedConversion(sink);
    var completed = false;
    try {
      decoder.add(bytes);
    } on _FirstLineComplete {
      completed = true;
    } on FormatException {
      if (!prefixOnly) rethrow;
      // A truncated gzip prefix that still flushed a complete first line is
      // usable; otherwise fall through to the empty-line error below.
    }
    if (!completed) {
      if (prefixOnly && bytes.length < _snapshotMetaProbeBytes) {
        // The probe covered the whole file: closing is safe and flushes any
        // remaining decompressed bytes.
        decoder.close();
      } else {
        // A snapshot without a trailing newline: closing flushes the remaining
        // decompressed bytes so the single meta line can be read.
        decoder.close();
      }
    }
    final line = utf8.decode(sink.takeBytes()).trim();
    if (line.isEmpty) throw const FormatException('Empty snapshot meta line');
    return line;
  }

  // -------------------------------------------------------------- transport --

  @override
  Future<List<RemoteDeviceInfo>> listDevices() {
    return _guard('listDevices', () async {
      final entries = await _io.list(paths.devicesDir);
      if (entries == null) return const <RemoteDeviceInfo>[];
      final ids = <String>{};
      for (final entry in entries) {
        final name = entry.name;
        if (entry.isDirectory) {
          if (hlcDeviceIdRegExp.hasMatch(name)) ids.add(name);
          continue;
        }
        if (!name.endsWith('.json')) continue;
        final deviceId = name.substring(0, name.length - 5);
        if (hlcDeviceIdRegExp.hasMatch(deviceId)) ids.add(deviceId);
      }
      final sorted = ids.toList()..sort();
      return [for (final id in sorted) RemoteDeviceInfo(deviceId: id)];
    });
  }

  @override
  Future<RemoteState?> readState(String deviceId) async {
    final path = paths.statePath(deviceId);
    return _guard('readState', () async {
      final bytes = await _io.read(path);
      if (bytes == null || bytes.isEmpty) return null;
      return decodeRemoteState(bytes);
    });
  }

  @override
  Future<void> writeState(String deviceId, RemoteState state) async {
    final path = paths.statePath(deviceId);
    if (state.deviceId != deviceId) {
      throw ArgumentError.value(
        state.deviceId,
        'state.deviceId',
        'Must match $deviceId',
      );
    }
    final bytes = encodeRemoteState(state);
    await _guard('writeState', () => _writeAtomic(path, bytes));
  }

  @override
  Future<List<ChangeRange>> listChanges(String deviceId) async {
    final deviceDir = paths.changesDir(deviceId);
    return _guard('listChanges', () => _listChangesAt(deviceDir));
  }

  @override
  Future<Uint8List?> readChanges(String deviceId, ChangeRange range) async {
    final path = paths.changeFilePath(deviceId, range.lo, range.hi);
    return _guard('readChanges', () => _io.read(path));
  }

  @override
  Future<void> writeChanges(
    String deviceId,
    int lo,
    int hi,
    Uint8List bytes,
  ) async {
    final path = paths.changeFilePath(deviceId, lo, hi);
    await _guard('writeChanges', () => _writeAtomic(path, bytes));
  }

  @override
  Future<Uint8List?> readSnapshot(String deviceId) async {
    final snapshot = paths.snapshotPath(deviceId);
    final previous = paths.snapshotPrevPath(deviceId);
    return _guard('readSnapshot', () async {
      final bytes = await _io.read(snapshot);
      if (bytes != null && bytes.isNotEmpty) return bytes;
      final previousBytes = await _io.read(previous);
      if (previousBytes != null && previousBytes.isNotEmpty) {
        return previousBytes;
      }
      return bytes;
    });
  }

  @override
  Future<SnapshotInfo?> readSnapshotInfo(String deviceId) async {
    final snapshot = paths.snapshotPath(deviceId);
    final previous = paths.snapshotPrevPath(deviceId);
    return _guard('readSnapshotInfo', () async {
      // Only the leading bytes are fetched: the meta line is the first
      // decompressed line, so a range request avoids downloading the whole
      // (potentially multi-MB) snapshot for a metadata probe.
      Uint8List? source;
      var prefixOnly = false;
      final bytes = await _io.readHead(snapshot, _snapshotMetaProbeBytes);
      if (bytes != null && bytes.isNotEmpty) {
        source = bytes;
        prefixOnly = true;
      } else {
        final previousBytes = await _io.readHead(
          previous,
          _snapshotMetaProbeBytes,
        );
        if (previousBytes == null || previousBytes.isEmpty) return null;
        source = previousBytes;
        prefixOnly = true;
      }
      try {
        return decodeSnapshotInfo(
          source,
          expectedDeviceId: deviceId,
          prefixOnly: prefixOnly,
        );
      } on FormatException catch (error) {
        if (!prefixOnly) rethrow;
        // A truncated prefix may fail to inflate; fall back to a full read.
        final full = await _io.read(snapshot) ?? await _io.read(previous);
        if (full == null || full.isEmpty) return null;
        try {
          return decodeSnapshotInfo(full, expectedDeviceId: deviceId);
        } on FormatException {
          throw error;
        }
      }
    });
  }

  @override
  Future<void> writeSnapshot(String deviceId, Uint8List bytes) async {
    final snapshot = paths.snapshotPath(deviceId);
    final previous = paths.snapshotPrevPath(deviceId);
    await _guard('writeSnapshot', () async {
      // Best effort: keep the last snapshot around for one cycle so a
      // non-atomic overwrite cannot leave readers without any snapshot.
      //
      // The first snapshot has no source file: some servers answer that MOVE
      // with 404, others (e.g. Alist) answer 500. A backup failure must never
      // fail the snapshot write itself, otherwise a brand-new device can never
      // upload its first snapshot.
      if (_moveSupported != false) {
        try {
          final result = await _io.move(snapshot, previous);
          if (result == WebDavMoveResult.unsupported) _moveSupported = false;
        } on SyncTransportException {
          // Ignore: backup is optional. The following PUT is authoritative.
        }
      }
      await _writeAtomic(snapshot, bytes);
    });
  }

  @override
  Future<Uint8List?> readBlob(String deviceId, String sha256) async {
    final path = paths.blobPath(deviceId, sha256);
    return _guard('readBlob', () => _io.read(path));
  }

  @override
  Future<List<String>> listBlobs(String deviceId) {
    final blobsDir = '${paths.deviceDir(deviceId)}/blobs';
    return _guard('listBlobs', () async {
      final entries = await _io.list(blobsDir);
      if (entries == null) return const <String>[];
      final names = <String>[];
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        // Stored as `<sha256>.gz`; strip both suffixes defensively.
        var name = entry.name;
        if (name.endsWith('.gz')) name = name.substring(0, name.length - 3);
        if (WebDavPaths.sha256RegExp.hasMatch(name)) names.add(name);
      }
      names.sort();
      return names;
    });
  }

  @override
  Future<void> deleteBlob(String deviceId, String sha256) async {
    final path = paths.blobPath(deviceId, sha256);
    await _guard('deleteBlob', () => _io.remove(path));
  }

  @override
  Future<void> writeBlob(
    String deviceId,
    String sha256,
    Uint8List bytes,
  ) async {
    final path = paths.blobPath(deviceId, sha256);
    await _guard('writeBlob', () => _writeAtomic(path, bytes));
  }

  @override
  Future<void> deleteChanges(String deviceId, int upToSeq) async {
    final deviceDir = paths.changesDir(deviceId);
    if (upToSeq < 0) {
      throw ArgumentError.value(upToSeq, 'upToSeq', 'Must be >= 0');
    }
    if (upToSeq == 0) return;
    await _guard('deleteChanges', () async {
      final ranges = await _listChangesAt(deviceDir);
      for (final range in ranges) {
        if (range.hi > upToSeq) continue;
        await _io.remove(paths.changeFilePath(deviceId, range.lo, range.hi));
      }
    });
  }

  @override
  Future<void> deleteDevice(String deviceId) async {
    final deviceDir = paths.deviceDir(deviceId);
    final state = paths.statePath(deviceId);
    await _guard('deleteDevice', () async {
      await _io.removeDirectory(deviceDir);
      await _io.remove(state);
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _io.close();
    } on Object {
      // Shutting down is best effort; nothing useful can be done here.
    }
  }

  // --------------------------------------------------------------- helpers --

  Future<List<ChangeRange>> _listChangesAt(String deviceDir) async {
    final entries = await _io.list(deviceDir);
    if (entries == null) return const <ChangeRange>[];
    final byRange = <String, ChangeRange>{};
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final range = WebDavPaths.parseChangeFileName(entry.name);
      if (range == null) continue;
      byRange['${range.lo}-${range.hi}'] = ChangeRange(
        lo: range.lo,
        hi: range.hi,
        etag: entry.etag,
        modified: entry.modified,
      );
    }
    final ranges = byRange.values.toList()
      ..sort((a, b) {
        final byLo = a.lo.compareTo(b.lo);
        return byLo != 0 ? byLo : a.hi.compareTo(b.hi);
      });
    return ranges;
  }

  /// Writes [bytes] to [path] using `tmp` + `MOVE` when the server supports
  /// it, falling back to a plain `PUT` (protocol doc §7.2 step 4).
  Future<void> _writeAtomic(String path, Uint8List bytes) async {
    if (_moveSupported == false) {
      await _io.write(path, bytes);
      return;
    }
    final tmp = '$path.tmp';
    await _io.write(tmp, bytes);
    final result = await _io.move(tmp, path);
    if (result == WebDavMoveResult.moved) return;
    if (result == WebDavMoveResult.unsupported) _moveSupported = false;
    await _io.write(path, bytes);
    try {
      await _io.remove(tmp);
    } on Object {
      // Leaving a stale `.tmp` file is harmless; it is never listed as data.
    }
  }

  Future<T> _guard<T>(String operation, Future<T> Function() action) async {
    if (_closed) {
      throw SyncTransportException('WebDAV sync transport is closed');
    }
    try {
      return await action();
    } on SyncTransportException {
      rethrow;
    } on DioException catch (error) {
      throw SyncTransportException(
        'WebDAV $operation failed: ${error.message ?? error.type.name}',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } on FormatException catch (error) {
      throw SyncTransportException(
        'WebDAV $operation returned invalid data: ${error.message}',
        cause: error,
      );
    } on ArgumentError catch (error) {
      throw SyncTransportException(
        'WebDAV $operation returned invalid data: ${error.message}',
        cause: error,
      );
    } on Object catch (error) {
      throw SyncTransportException(
        'WebDAV $operation failed: $error',
        cause: error,
      );
    }
  }
}

/// Collects decompressed bytes up to (excluding) the first newline and then
/// aborts the inflation, which keeps snapshot meta reads cheap.
class _FirstLineSink implements Sink<List<int>> {
  _FirstLineSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  var _length = 0;

  @override
  void add(List<int> data) {
    final newline = data.indexOf(10);
    if (newline >= 0) {
      _append(data, newline);
      throw const _FirstLineComplete();
    }
    _append(data, data.length);
  }

  void _append(List<int> data, int length) {
    if (length <= 0) return;
    _length += length;
    if (_length > limit) {
      throw const FormatException('Snapshot meta line too long');
    }
    _builder.add(data.sublist(0, length));
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

class _FirstLineComplete implements Exception {
  const _FirstLineComplete();
}
