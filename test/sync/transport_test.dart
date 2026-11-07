import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show ContentType, HttpClient, HttpServer, InternetAddress, gzip;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:dio/dio.dart'
    show
        DioException,
        DioExceptionType,
        HttpClientAdapter,
        RequestOptions,
        Response,
        ResponseBody;
import 'package:dio/io.dart' show IOHttpClientAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/fake_transport.dart';
import 'package:venera/sync/hlc.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/snapshot.dart';
import 'package:venera/sync/transport.dart';
import 'package:venera/sync/version.dart';
import 'package:venera/sync/webdav_transport.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

const String _deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
const String _deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';
const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

RemoteState _state(
  String deviceId, {
  int lastChange = 3,
  Map<String, int>? applied,
  SnapshotInfo? snapshot,
}) {
  return RemoteState(
    deviceId: deviceId,
    updatedHlc: Hlc(ms: 1000, counter: lastChange, deviceId: deviceId),
    lastChange: lastChange,
    applied: applied ?? {deviceId: lastChange},
    snapshot: snapshot,
    lastSeen: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
  );
}

SnapshotInfo _info(
  String deviceId, {
  int rangeLo = 1,
  int rangeHi = 7,
  Set<String> domains = const {'history'},
  Map<String, int>? applied,
}) {
  return SnapshotInfo(
    deviceId: deviceId,
    hlc: Hlc(ms: 5000, counter: 0, deviceId: deviceId),
    rangeLo: rangeLo,
    rangeHi: rangeHi,
    applied: applied ?? {deviceId: rangeHi},
    domains: domains,
  );
}

Uint8List _snapshotBytes(SnapshotInfo info, {int fillerRecords = 0}) {
  return SnapshotCodec.encode(info, const {}, [
    SnapshotRecord(
      domain: 'history',
      key: SyncKey(['abc', '1']),
      field: 'progress',
      version: Version(Hlc(ms: 10, counter: 0, deviceId: info.deviceId), 1),
      data: {'ep': 1, 'page': 2},
    ),
    for (var i = 0; i < fillerRecords; i++)
      SnapshotRecord(
        domain: 'history',
        key: SyncKey(['filler-$i', '1']),
        field: 'progress',
        version: Version(Hlc(ms: 10, counter: 0, deviceId: info.deviceId), 1),
        data: {'ep': i, 'page': 0},
      ),
  ]);
}

void _expectState(RemoteState? actual, RemoteState expected) {
  expect(actual, isNotNull);
  expect(actual!.deviceId, expected.deviceId);
  expect(actual.protocol, expected.protocol);
  expect(actual.updatedHlc, expected.updatedHlc);
  expect(actual.lastChange, expected.lastChange);
  expect(actual.applied, expected.applied);
  expect(actual.snapshot?.toJson(), expected.snapshot?.toJson());
  expect(actual.lastSeen?.toUtc(), expected.lastSeen?.toUtc());
}

/// Adapter that fails the test if the seam test ever performs a request.
class _NeverUsedAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw StateError('The network must not be used in tests');
  }
}

/// Minimal in-memory [WebDavIo] used to exercise [WebDavSyncTransport] without
/// a network or a display. Paths are the already-encoded v2 relative paths.
class _FakeWebDavIo implements WebDavIo {
  final Map<String, Uint8List> files = {};
  final List<String> requests = [];

  bool moveSupported = true;
  bool failMoves = false;
  Exception? readError;
  bool closed = false;

  @override
  Future<List<WebDavEntry>?> list(String path) async {
    _record('PROPFIND', path);
    final normalized = path.replaceAll(RegExp(r'/+$'), '');
    final prefix = '$normalized/';
    final entries = <String, bool>{};
    for (final file in files.keys) {
      if (!file.startsWith(prefix)) continue;
      final rest = file.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        entries[rest] = false;
      } else {
        entries[rest.substring(0, slash)] = true;
      }
    }
    if (entries.isEmpty) return null;
    final names = entries.keys.toList()..sort();
    return [
      for (final name in names)
        WebDavEntry(
          name: name,
          path: '$prefix$name',
          isDirectory: entries[name]!,
          etag: 'etag:$name',
        ),
    ];
  }

  @override
  Future<Uint8List?> read(String path) async {
    _record('GET', path);
    final error = readError;
    if (error != null) throw error;
    final bytes = files[path];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> readHead(String path, int maxLength) async {
    _record('GET-HEAD', path);
    final error = readError;
    if (error != null) throw error;
    final bytes = files[path];
    if (bytes == null) return null;
    return Uint8List.fromList(
      bytes.length <= maxLength ? bytes : bytes.sublist(0, maxLength),
    );
  }

  @override
  Future<bool> exists(String path) async {
    _record('PROPFIND-ONE', path);
    return files.containsKey(path);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    _record('PUT', path);
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<WebDavMoveResult> move(String from, String to) async {
    _record('MOVE', from, extra: to);
    if (failMoves) {
      throw SyncTransportException('MOVE failed', statusCode: 500);
    }
    if (!moveSupported) return WebDavMoveResult.unsupported;
    final bytes = files.remove(from);
    if (bytes == null) return WebDavMoveResult.notFound;
    files[to] = bytes;
    return WebDavMoveResult.moved;
  }

  @override
  Future<void> remove(String path) async {
    _record('DELETE', path);
    files.remove(path);
  }

  @override
  Future<void> removeDirectory(String path) async {
    _record('DELETE-DIR', path);
    final prefix = path.replaceAll(RegExp(r'/+$'), '');
    files.removeWhere((key, _) => key == prefix || key.startsWith('$prefix/'));
  }

  @override
  Future<void> close() async {
    _record('CLOSE', '');
    closed = true;
  }

  void _record(String method, String path, {String? extra}) {
    requests.add('$method $path${extra == null ? '' : ' -> $extra'}');
  }

  Iterable<String> requestsOf(String method) =>
      requests.where((request) => request.startsWith('$method '));
}

void main() {
  test(
    'clientFactory seam builds a transport without any network access',
    () async {
      var created = 0;
      final transport = WebDavSyncTransport.connect(
        baseUrl: ' https://dav.example/books ',
        user: 'user',
        password: 'pass',
        clientFactory: (baseUrl, user, password) {
          created++;
          expect(baseUrl, 'https://dav.example/books');
          expect(user, 'user');
          expect(password, 'pass');
          return webdav.newClient(
            baseUrl,
            user: user,
            password: password,
            adapter: _NeverUsedAdapter(),
          );
        },
      );
      expect(created, 1);
      expect(transport.paths.statePath(_deviceA), 'v2/devices/$_deviceA.json');
      await transport.close();
      await transport.close();
    },
  );

  test('connect validates the base url before creating a client', () {
    var created = 0;
    expect(
      () => WebDavSyncTransport.connect(
        baseUrl: 'ftp://example.com/dav',
        clientFactory: (baseUrl, user, password) {
          created++;
          return webdav.newClient(baseUrl, adapter: _NeverUsedAdapter());
        },
      ),
      throwsArgumentError,
    );
    expect(created, 0);
  });

  test('listDevices ignores stale .json.tmp atomic-write leftovers', () async {
    // A minimal WebDAV server that only answers PROPFIND on /devices with
    // a fixed directory listing: one live state file, one in-flight tmp and
    // unrelated junk names.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // The first response must be the directory itself: the webdav_client
    // parser skips it by position (not href), and rejects listings whose
    // first entry is not a collection.
    const body =
        ''
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/dav/v2/devices/</D:href>'
        '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '<D:response><D:href>/dav/v2/devices/$_deviceA.json</D:href>'
        '<D:propstat><D:prop><D:resourcetype/></D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '<D:response><D:href>/dav/v2/devices/$_deviceB.json.tmp</D:href>'
        '<D:propstat><D:prop><D:resourcetype/></D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '<D:response><D:href>/dav/v2/devices/not-a-device.json</D:href>'
        '<D:propstat><D:prop><D:resourcetype/></D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '</D:multistatus>';
    server.listen((request) async {
      // Ignore anything but the devices listing (e.g. keep-alive probes).
      // The client normalizes the path with a trailing slash.
      final normalized = request.uri.path.replaceAll(RegExp(r'/+$'), '');
      if (request.method != 'PROPFIND' || !normalized.endsWith('/devices')) {
        request.response
          ..statusCode = 404
          ..close();
        return;
      }
      request.response
        ..statusCode = 207
        ..headers.contentType = ContentType('application', 'xml')
        ..write(body)
        ..close();
    });

    final transport = WebDavSyncTransport.connect(
      baseUrl: 'http://127.0.0.1:${server.port}/dav',
      user: 'user',
      password: 'pass',
      // The app default uses a rust-backed adapter that is unavailable in
      // the flutter_test sandbox; plain dart:io HTTP works here.
      clientFactory: (baseUrl, user, password) => webdav.newClient(
        baseUrl,
        user: user,
        password: password,
        adapter: IOHttpClientAdapter(createHttpClient: () => HttpClient()),
      ),
    );
    addTearDown(transport.close);

    final devices = await transport.listDevices();
    // The tmp leftover must not surface as a ghost device; junk names are
    // filtered; the real state document is discovered.
    expect(devices.map((info) => info.deviceId), [_deviceA]);
    expect(devices.map((info) => info.deviceId), isNot(contains(_deviceB)));
    expect(
      devices.map((info) => info.deviceId),
      isNot(contains('not-a-device')),
    );
  });

  group('WebDavPaths', () {
    final paths = WebDavPaths();

    test('builds the documented v2 layout', () {
      expect(paths.devicesDir, 'v2/devices');
      expect(paths.statePath(_deviceA), 'v2/devices/$_deviceA.json');
      expect(paths.deviceDir(_deviceA), 'v2/devices/$_deviceA');
      expect(
        paths.deviceMetaPath(_deviceA),
        'v2/devices/$_deviceA/device.json',
      );
      expect(paths.changesDir(_deviceA), 'v2/devices/$_deviceA/changes');
      expect(
        paths.changeFilePath(_deviceA, 1, 42),
        'v2/devices/$_deviceA/changes/'
        '000000000001-000000000042.jsonl.gz',
      );
      expect(
        paths.snapshotPath(_deviceA),
        'v2/devices/$_deviceA/snapshot.jsonl.gz',
      );
      expect(
        paths.snapshotPrevPath(_deviceA),
        'v2/devices/$_deviceA/snapshot.prev.jsonl.gz',
      );
      expect(
        paths.blobPath(_deviceA, _sha),
        'v2/devices/$_deviceA/blobs/$_sha.gz',
      );
    });

    test('encodes every segment and normalizes the root', () {
      final custom = WebDavPaths('/folder name//v2/');
      expect(custom.root, 'folder%20name/v2');
      expect(WebDavPaths.encodeSegment('a b/c'), 'a%20b%2Fc');
      expect(() => WebDavPaths('///'), throwsArgumentError);
    });

    test('rejects hostile or malformed segments', () {
      expect(() => paths.statePath('../evil'), throwsArgumentError);
      expect(() => paths.statePath(''), throwsArgumentError);
      expect(() => paths.deviceDir('a/b'), throwsArgumentError);
      expect(() => paths.blobPath(_deviceA, 'ABC'), throwsArgumentError);
      expect(
        () => paths.blobPath(_deviceA, _sha.replaceRange(0, 1, 'G')),
        throwsArgumentError,
      );
      expect(() => paths.changeFilePath(_deviceA, 0, 2), throwsArgumentError);
      expect(() => paths.changeFilePath(_deviceA, 5, 4), throwsArgumentError);
      expect(
        () => paths.changeFilePath(_deviceA, 1, 1000000000000),
        throwsArgumentError,
      );
    });

    test('change file names are 12-digit zero padded and roundtrip', () {
      expect(
        WebDavPaths.changeFileName(58, 91),
        '000000000058-000000000091.jsonl.gz',
      );
      final parsed = WebDavPaths.parseChangeFileName(
        WebDavPaths.changeFileName(58, 91),
      );
      expect(parsed, isNotNull);
      expect(parsed!.lo, 58);
      expect(parsed.hi, 91);

      expect(WebDavPaths.parseChangeFileName('1-42.jsonl.gz'), isNull);
      expect(
        WebDavPaths.parseChangeFileName('000000000001-000000000042.jsonl'),
        isNull,
      );
      expect(
        WebDavPaths.parseChangeFileName(
          '000000000001-000000000042.jsonl.gz.tmp',
        ),
        isNull,
      );
      expect(
        WebDavPaths.parseChangeFileName('000000000000-000000000042.jsonl.gz'),
        isNull,
      );
      expect(
        WebDavPaths.parseChangeFileName('000000000042-000000000001.jsonl.gz'),
        isNull,
      );
      expect(WebDavPaths.parseChangeFileName('README.txt'), isNull);
    });
  });

  group('WebDavSyncTransport pure helpers', () {
    test('normalizes the configured WebDAV URL', () {
      expect(
        WebDavSyncTransport.normalizeBaseUrl(' https://dav.example/books '),
        'https://dav.example/books',
      );
      expect(
        WebDavSyncTransport.normalizeBaseUrl('http://127.0.0.1:8080/dav/'),
        'http://127.0.0.1:8080/dav/',
      );
      expect(
        WebDavSyncTransport.normalizeBaseUrl('https://dav.example/my books'),
        'https://dav.example/my%20books',
      );
      expect(
        () => WebDavSyncTransport.normalizeBaseUrl(''),
        throwsArgumentError,
      );
      expect(
        () => WebDavSyncTransport.normalizeBaseUrl('/relative/path'),
        throwsArgumentError,
      );
      expect(
        () => WebDavSyncTransport.normalizeBaseUrl('ftp://example.com/x'),
        throwsArgumentError,
      );
    });

    test('remote state json roundtrip', () {
      final original = _state(
        _deviceA,
        lastChange: 91,
        applied: {_deviceA: 91, _deviceB: 33},
        snapshot: _info(_deviceA, rangeHi: 57),
      );
      final decoded = WebDavSyncTransport.decodeRemoteState(
        WebDavSyncTransport.encodeRemoteState(original),
      );
      _expectState(decoded, original);
      expect(decoded.toJson()['snapshot'], isA<Map>());
    });

    test('rejects malformed remote state json', () {
      expect(
        () => WebDavSyncTransport.decodeRemoteState(
          Uint8List.fromList(utf8.encode('not json')),
        ),
        throwsFormatException,
      );
      expect(
        () => WebDavSyncTransport.decodeRemoteState(
          Uint8List.fromList(utf8.encode('[1,2,3]')),
        ),
        throwsFormatException,
      );
      expect(
        () => WebDavSyncTransport.decodeRemoteState(
          Uint8List.fromList(
            utf8.encode(
              '{"protocol":2,"device":"$_deviceA",'
              '"updatedHlc":"nope","lastChange":1,"applied":{}}',
            ),
          ),
        ),
        throwsFormatException,
      );
    });

    test('decodes only the snapshot meta line', () {
      final info = _info(_deviceA, rangeHi: 7);
      final bytes = _snapshotBytes(info);
      final decoded = WebDavSyncTransport.decodeSnapshotInfo(
        bytes,
        expectedDeviceId: _deviceA,
      );
      expect(decoded.deviceId, _deviceA);
      expect(decoded.hlc, info.hlc);
      expect(decoded.rangeLo, 1);
      expect(decoded.rangeHi, 7);
      expect(decoded.domains, info.domains);
      expect(
        () => WebDavSyncTransport.decodeSnapshotInfo(
          bytes,
          expectedDeviceId: _deviceB,
        ),
        throwsFormatException,
      );
      expect(
        () => WebDavSyncTransport.decodeSnapshotInfo(Uint8List(0)),
        throwsFormatException,
      );
      expect(
        () => WebDavSyncTransport.decodeSnapshotInfo(
          Uint8List.fromList(const [1, 2, 3, 4]),
        ),
        throwsFormatException,
      );
    });

    test('snapshot meta decoding does not inflate the whole snapshot', () {
      // Build a gzip stream whose body is far larger than SyncOpCodec's
      // 2 MiB compressed limit; the meta line must still be readable.
      final info = _info(_deviceA);
      final meta = jsonEncode(info.toJson()..['snapshot'] = true);
      final builder = BytesBuilder(copy: false);
      builder.add(utf8.encode('$meta\n'));
      final random = Random(42);
      final noise = Uint8List(3 << 20);
      for (var i = 0; i < noise.length; i++) {
        noise[i] = random.nextInt(256);
      }
      builder.add(noise);
      final compressed = Uint8List.fromList(gzip.encode(builder.takeBytes()));
      expect(compressed.length, greaterThan(SyncOpCodec.maxCompressedBytes));
      final decoded = WebDavSyncTransport.decodeSnapshotInfo(compressed);
      expect(decoded.deviceId, _deviceA);
    });
  });

  group('FakeTransport contract', () {
    late FakeRemote remote;
    late FakeTransport transport;

    setUp(() {
      remote = FakeRemote();
      transport = FakeTransport(remote);
    });

    test('devices share one remote', () async {
      final other = FakeTransport(remote);
      await transport.writeState(_deviceA, _state(_deviceA));
      await other.writeState(_deviceB, _state(_deviceB));

      final devices = await transport.listDevices();
      expect(devices.map((info) => info.deviceId), [_deviceA, _deviceB]);
      _expectState(await other.readState(_deviceA), _state(_deviceA));
    });

    test('state roundtrip, copies and invalid ids', () async {
      final original = _state(
        _deviceA,
        lastChange: 91,
        applied: {_deviceA: 91, _deviceB: 33},
        snapshot: _info(_deviceA, rangeHi: 57),
      );
      await transport.writeState(_deviceA, original);
      final read = await transport.readState(_deviceA);
      _expectState(read, original);

      // Reads are defensive copies: mutating the returned map must not touch
      // the remote.
      read!.applied[_deviceA] = 0;
      _expectState(await transport.readState(_deviceA), original);

      expect(await transport.readState(_deviceB), isNull);
      await expectLater(transport.readState('../evil'), throwsArgumentError);
      await expectLater(
        transport.writeState(_deviceB, _state(_deviceA)),
        throwsArgumentError,
      );
      await expectLater(
        transport.writeState(_deviceB, _state(_deviceB)),
        completes,
      );
    });

    test('state faults: read failure, corrupt json, stale state', () async {
      final first = _state(_deviceA, lastChange: 1);
      await transport.writeState(_deviceA, first);

      remote.staleState(_deviceA);
      await transport.writeState(_deviceA, _state(_deviceA, lastChange: 2));
      _expectState(await transport.readState(_deviceA), first);
      remote.clearStaleState(_deviceA);
      _expectState(
        await transport.readState(_deviceA),
        _state(_deviceA, lastChange: 2),
      );

      remote.corruptState(_deviceA);
      await expectLater(
        transport.readState(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
      remote.corruptState(_deviceA, enabled: false);

      remote.failStateRead(_deviceA);
      await expectLater(
        transport.readState(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
      // Directory-level detection still works while the state file is
      // unreadable (protocol §7.3).
      expect(
        (await transport.listDevices()).map((info) => info.deviceId),
        contains(_deviceA),
      );
      remote.failStateRead(_deviceA, enabled: false);
      _expectState(
        await transport.readState(_deviceA),
        _state(_deviceA, lastChange: 2),
      );
    });

    test('changes: write, list, read, gaps and corruption', () async {
      await transport.writeChanges(_deviceA, 1, 2, Uint8List.fromList([1]));
      await transport.writeChanges(_deviceA, 3, 4, Uint8List.fromList([2]));
      await transport.writeChanges(_deviceA, 5, 6, Uint8List.fromList([3]));

      var ranges = await transport.listChanges(_deviceA);
      expect(ranges.map((range) => '${range.lo}-${range.hi}'), [
        '1-2',
        '3-4',
        '5-6',
      ]);
      expect(
        await transport.readChanges(_deviceA, ranges[1]),
        Uint8List.fromList([2]),
      );

      remote.missingChange(_deviceA, 3, 4);
      ranges = await transport.listChanges(_deviceA);
      expect(ranges.map((range) => '${range.lo}-${range.hi}'), ['1-2', '5-6']);
      expect(
        await transport.readChanges(_deviceA, const ChangeRange(lo: 3, hi: 4)),
        isNull,
      );

      remote.missingCorruptChange(_deviceA, 5, 6);
      ranges = await transport.listChanges(_deviceA);
      expect(ranges.map((range) => '${range.lo}-${range.hi}'), ['1-2']);
      final corrupt = await transport.readChanges(
        _deviceA,
        const ChangeRange(lo: 5, hi: 6),
      );
      expect(corrupt, isNotNull);
      expect(
        () => SyncOpCodec.decode(
          corrupt!,
          expectedDeviceId: _deviceA,
          lo: 5,
          hi: 6,
        ),
        throwsA(isA<FormatException>()),
      );

      remote.clearChangeFault(_deviceA, 3, 4);
      remote.clearChangeFault(_deviceA, 5, 6);
      expect((await transport.listChanges(_deviceA)).length, 3);
      expect(await transport.listChanges(_deviceB), isEmpty);
      expect(
        await transport.readChanges(_deviceA, const ChangeRange(lo: 9, hi: 9)),
        isNull,
      );
      await expectLater(
        transport.writeChanges(_deviceA, 0, 1, Uint8List(1)),
        throwsArgumentError,
      );
      await expectLater(
        transport.writeChanges(_deviceA, 5, 4, Uint8List(1)),
        throwsArgumentError,
      );
    });

    test(
      'delete changes removes complete ranges up to the watermark',
      () async {
        for (var lo = 1; lo <= 5; lo += 2) {
          await transport.writeChanges(
            _deviceA,
            lo,
            lo + 1,
            Uint8List.fromList([lo]),
          );
        }
        await transport.writeChanges(_deviceA, 7, 9, Uint8List.fromList([7]));
        await transport.deleteChanges(_deviceA, 0);
        expect((await transport.listChanges(_deviceA)).length, 4);
        await transport.deleteChanges(_deviceA, 4);
        final ranges = await transport.listChanges(_deviceA);
        expect(ranges.map((range) => '${range.lo}-${range.hi}'), [
          '5-6',
          '7-9',
        ]);
        await transport.deleteChanges(_deviceA, 100);
        expect(await transport.listChanges(_deviceA), isEmpty);
        await expectLater(
          transport.deleteChanges(_deviceA, -1),
          throwsArgumentError,
        );
      },
    );

    test('snapshot read/write keeps the previous snapshot', () async {
      final info = _info(_deviceA);
      final first = _snapshotBytes(info);
      final second = _snapshotBytes(_info(_deviceA, rangeHi: 9));

      await transport.writeSnapshot(_deviceA, first);
      expect(await transport.readSnapshot(_deviceA), first);
      final readInfo = await transport.readSnapshotInfo(_deviceA);
      expect(readInfo?.rangeHi, 7);

      await transport.writeSnapshot(_deviceA, second);
      expect(await transport.readSnapshot(_deviceA), second);
      expect(remote.debugSnapshotPrev(_deviceA), first);
      expect((await transport.readSnapshotInfo(_deviceA))?.rangeHi, 9);
    });

    test(
      'partial snapshot is undecodable and reported as invalid info',
      () async {
        final bytes = _snapshotBytes(_info(_deviceA));
        await transport.writeSnapshot(_deviceA, bytes);
        remote.injectPartialSnapshot(_deviceA, length: 4);
        final partial = await transport.readSnapshot(_deviceA);
        expect(partial, isNotNull);
        expect(partial!.length, 4);
        await expectLater(
          transport.readSnapshotInfo(_deviceA),
          throwsA(isA<SyncTransportException>()),
        );
        remote.clearPartialSnapshot(_deviceA);
        expect(await transport.readSnapshot(_deviceA), bytes);
      },
    );

    test('device mismatch in snapshot info is rejected', () async {
      final foreign = _snapshotBytes(_info(_deviceB));
      await transport.writeSnapshot(_deviceA, foreign);
      await expectLater(
        transport.readSnapshotInfo(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
    });

    test('blobs are content addressed and validated', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(await transport.readBlob(_deviceA, _sha), isNull);
      await transport.writeBlob(_deviceA, _sha, bytes);
      expect(await transport.readBlob(_deviceA, _sha), bytes);
      expect(await transport.readBlob(_deviceB, _sha), isNull);
      await expectLater(
        transport.writeBlob(_deviceA, 'ABC', bytes),
        throwsArgumentError,
      );
      await expectLater(
        transport.readBlob(_deviceA, _sha.toUpperCase()),
        throwsArgumentError,
      );
    });

    test('deleteDevice drops every branch file', () async {
      await transport.writeState(_deviceA, _state(_deviceA));
      await transport.writeChanges(_deviceA, 1, 1, Uint8List.fromList([1]));
      await transport.writeSnapshot(_deviceA, _snapshotBytes(_info(_deviceA)));
      await transport.writeBlob(_deviceA, _sha, Uint8List.fromList([1]));
      await transport.writeState(_deviceB, _state(_deviceB));

      await transport.deleteDevice(_deviceA);
      expect(await transport.readState(_deviceA), isNull);
      expect(await transport.listChanges(_deviceA), isEmpty);
      expect(await transport.readSnapshot(_deviceA), isNull);
      expect(await transport.readBlob(_deviceA, _sha), isNull);
      expect((await transport.listDevices()).map((info) => info.deviceId), [
        _deviceB,
      ]);
    });

    test('write failures are retry idempotent', () async {
      final bytes = Uint8List.fromList([9, 8, 7]);
      remote.failNextWrite();
      await expectLater(
        transport.writeChanges(_deviceA, 1, 2, bytes),
        throwsA(isA<SyncTransportException>()),
      );
      expect(await transport.listChanges(_deviceA), isEmpty);

      await transport.writeChanges(_deviceA, 1, 2, bytes);
      expect((await transport.listChanges(_deviceA)).length, 1);
      expect(
        await transport.readChanges(_deviceA, const ChangeRange(lo: 1, hi: 2)),
        bytes,
      );
    });

    test('ambiguous (after-commit) write failure stays idempotent', () async {
      final bytes = Uint8List.fromList([4, 5, 6]);
      remote.failNextWrite(afterCommit: true);
      await expectLater(
        transport.writeChanges(_deviceA, 1, 1, bytes),
        throwsA(isA<SyncTransportException>()),
      );
      // Data landed anyway; retrying the same content must not duplicate it.
      await transport.writeChanges(_deviceA, 1, 1, bytes);
      final ranges = await transport.listChanges(_deviceA);
      expect(ranges.length, 1);
      expect(
        await transport.readChanges(_deviceA, const ChangeRange(lo: 1, hi: 1)),
        bytes,
      );
    });

    test('latency hook is an awaitable gap', () async {
      final gate = Completer<void>();
      remote.onRequest = () => gate.future;
      var completed = false;
      final future = transport.readState(_deviceA).whenComplete(() {
        completed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      gate.complete();
      remote.onRequest = null;
      await expectLater(future, completion(isNull));
      expect(completed, isTrue);
    });

    test('unavailable, read-only and write-only modes', () async {
      remote.setUnavailable(true);
      await expectLater(
        transport.listDevices(),
        throwsA(isA<SyncTransportException>()),
      );
      await expectLater(
        transport.writeState(_deviceA, _state(_deviceA)),
        throwsA(isA<SyncTransportException>()),
      );
      remote.setUnavailable(false);

      remote.setReadOnly(true);
      expect(await transport.listDevices(), isEmpty);
      await expectLater(
        transport.writeState(_deviceA, _state(_deviceA)),
        throwsA(
          isA<SyncTransportException>().having(
            (error) => error.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      remote.setReadOnly(false);

      remote.setWriteOnly(true);
      await transport.writeState(_deviceA, _state(_deviceA));
      await expectLater(
        transport.readState(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
      remote.setWriteOnly(false);
      _expectState(await transport.readState(_deviceA), _state(_deviceA));
    });

    test('close is idempotent and rejects further calls', () async {
      await transport.close();
      await transport.close();
      await expectLater(
        transport.listDevices(),
        throwsA(isA<SyncTransportException>()),
      );
    });

    test('faults can be cleared without touching data', () async {
      await transport.writeState(_deviceA, _state(_deviceA));
      remote.corruptState(_deviceA);
      await expectLater(
        transport.readState(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
      remote.clearFaults();
      _expectState(await transport.readState(_deviceA), _state(_deviceA));
      expect(transport.isClosed, isFalse);
    });
  });

  group('WebDavSyncTransport over fake io', () {
    late _FakeWebDavIo io;
    late WebDavSyncTransport transport;
    final paths = WebDavPaths();

    setUp(() {
      io = _FakeWebDavIo();
      transport = WebDavSyncTransport.withIo(io);
    });

    test('listDevices reads the devices/ collection only', () async {
      expect(await transport.listDevices(), isEmpty);

      await transport.writeState(_deviceA, _state(_deviceA));
      await transport.writeState(_deviceB, _state(_deviceB));
      // Ignored junk: non-hex name, non-json file, directory named like junk.
      io.files['v2/devices/not-a-device.json'] = Uint8List(1);
      io.files['v2/devices/notes.txt'] = Uint8List(1);
      io.files['v2/devices/zzz/device.json'] = Uint8List(1);

      io.requests.clear();
      final devices = await transport.listDevices();
      expect(devices.map((info) => info.deviceId), [_deviceA, _deviceB]);
      expect(io.requestsOf('PROPFIND').length, 1);
    });

    test('state uses tmp + MOVE and reads back', () async {
      final state = _state(
        _deviceA,
        lastChange: 91,
        applied: {_deviceA: 91, _deviceB: 33},
        snapshot: _info(_deviceA, rangeHi: 57),
      );
      await transport.writeState(_deviceA, state);
      expect(io.files.containsKey('${paths.statePath(_deviceA)}.tmp'), isFalse);
      expect(io.files.containsKey(paths.statePath(_deviceA)), isTrue);
      expect(io.requestsOf('MOVE').length, 1);
      expect(io.requestsOf('PUT').length, 1);
      _expectState(await transport.readState(_deviceA), state);
    });

    test(
      'failing MOVE degrades to plain PUT instead of failing the write',
      () async {
        // Some servers (Alist/OpenList) answer every MOVE with 5xx; writes must
        // still succeed and later writes must skip the doomed tmp+MOVE dance.
        io.failMoves = true;
        final state = _state(_deviceA, lastChange: 5);
        await transport.writeState(_deviceA, state);
        expect(io.files.containsKey(paths.statePath(_deviceA)), isTrue);
        expect(
          io.files.containsKey('${paths.statePath(_deviceA)}.tmp'),
          isFalse,
          reason: 'fallback must clean up the tmp file',
        );
        _expectState(await transport.readState(_deviceA), state);

        io.requests.clear();
        await transport.writeState(_deviceA, _state(_deviceA, lastChange: 6));
        expect(
          io.requestsOf('MOVE'),
          isEmpty,
          reason: 'a failed MOVE must disable tmp+MOVE for the session',
        );
        expect(io.requestsOf('PUT').length, greaterThanOrEqualTo(1));
        _expectState(
          await transport.readState(_deviceA),
          _state(_deviceA, lastChange: 6),
        );
      },
    );

    test('MOVE fallback writes via PUT and stops trying MOVE', () async {
      io.moveSupported = false;
      final state = _state(_deviceA);
      await transport.writeState(_deviceA, state);
      expect(io.requestsOf('MOVE').length, 1);
      expect(io.files.containsKey('${paths.statePath(_deviceA)}.tmp'), isFalse);
      _expectState(await transport.readState(_deviceA), state);

      await transport.writeState(_deviceA, _state(_deviceA, lastChange: 4));
      expect(io.requestsOf('MOVE').length, 1);
      _expectState(
        await transport.readState(_deviceA),
        _state(_deviceA, lastChange: 4),
      );
    });

    test('readState maps absent/corrupt files', () async {
      expect(await transport.readState(_deviceA), isNull);
      io.files[paths.statePath(_deviceA)] = Uint8List.fromList(
        utf8.encode('{"broken":true}'),
      );
      await expectLater(
        transport.readState(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
    });

    test('listChanges parses only strict file names, sorted', () async {
      await transport.writeChanges(_deviceA, 7, 9, Uint8List.fromList([7]));
      await transport.writeChanges(_deviceA, 1, 2, Uint8List.fromList([1]));
      await transport.writeChanges(_deviceA, 3, 4, Uint8List.fromList([3]));

      final changesDir = paths.changesDir(_deviceA);
      io.files['$changesDir/000000000005-000000000006.jsonl.gz.tmp'] =
          Uint8List(1);
      io.files['$changesDir/00000000000-000000000005.jsonl.gz'] = Uint8List(1);
      io.files['$changesDir/README.txt'] = Uint8List(1);
      io.files['$changesDir/nested/000000000010-000000000010.jsonl.gz'] =
          Uint8List(1);

      final ranges = await transport.listChanges(_deviceA);
      expect(ranges.map((range) => '${range.lo}-${range.hi}'), [
        '1-2',
        '3-4',
        '7-9',
      ]);
      expect(ranges.first.etag, isNotNull);
      expect(await transport.listChanges(_deviceB), isEmpty);
    });

    test('change files use the padded remote name', () async {
      final bytes = Uint8List.fromList([42]);
      await transport.writeChanges(_deviceA, 1, 42, bytes);
      final name =
          'v2/devices/$_deviceA/changes/'
          '000000000001-000000000042.jsonl.gz';
      expect(io.files[name], bytes);
      expect(
        await transport.readChanges(_deviceA, const ChangeRange(lo: 1, hi: 42)),
        bytes,
      );
      expect(
        await transport.readChanges(_deviceA, const ChangeRange(lo: 2, hi: 3)),
        isNull,
      );
    });

    test('deleteChanges removes only fully covered ranges', () async {
      await transport.writeChanges(_deviceA, 1, 2, Uint8List.fromList([1]));
      await transport.writeChanges(_deviceA, 3, 4, Uint8List.fromList([3]));
      await transport.writeChanges(_deviceA, 5, 9, Uint8List.fromList([5]));
      await transport.deleteChanges(_deviceA, 4);
      final ranges = await transport.listChanges(_deviceA);
      expect(ranges.map((range) => '${range.lo}-${range.hi}'), ['5-9']);
    });

    test('snapshot write preserves the previous snapshot via MOVE', () async {
      final first = _snapshotBytes(_info(_deviceA));
      await transport.writeSnapshot(_deviceA, first);
      final second = _snapshotBytes(_info(_deviceA, rangeHi: 9));
      await transport.writeSnapshot(_deviceA, second);

      expect(io.files[paths.snapshotPath(_deviceA)], second);
      expect(io.files[paths.snapshotPrevPath(_deviceA)], first);
      expect(await transport.readSnapshot(_deviceA), second);
      final info = await transport.readSnapshotInfo(_deviceA);
      expect(info?.rangeHi, 9);

      // Reading falls back to the previous snapshot when the current file is
      // gone.
      io.files.remove(paths.snapshotPath(_deviceA));
      final fallback = await transport.readSnapshot(_deviceA);
      expect(fallback, first);
      expect((await transport.readSnapshotInfo(_deviceA))?.rangeHi, 7);
    });

    test('readSnapshotInfo fetches only a prefix of the snapshot', () async {
      // A snapshot whose meta line is well inside the first deflate block:
      // a 4 KiB range request must be able to decode it without reading the
      // rest of the file.
      final big = _snapshotBytes(_info(_deviceA), fillerRecords: 2000);
      expect(big.length, greaterThan(4096));
      await transport.writeSnapshot(_deviceA, big);

      io.requests.clear();
      final info = await transport.readSnapshotInfo(_deviceA);

      expect(info?.rangeHi, 7);
      expect(
        io.requestsOf('GET-HEAD'),
        isNotEmpty,
        reason: 'the probe must use the head read, not a full GET',
      );
      expect(io.requestsOf('GET'), isEmpty);
    });

    test('snapshot without MOVE support still writes', () async {
      io.moveSupported = false;
      final first = _snapshotBytes(_info(_deviceA));
      await transport.writeSnapshot(_deviceA, first);
      final second = _snapshotBytes(_info(_deviceA, rangeHi: 9));
      await transport.writeSnapshot(_deviceA, second);
      expect(io.files[paths.snapshotPath(_deviceA)], second);
      expect(io.files.containsKey(paths.snapshotPrevPath(_deviceA)), isFalse);
    });

    test('readSnapshotInfo rejects a foreign device id', () async {
      io.files[paths.snapshotPath(_deviceA)] = _snapshotBytes(_info(_deviceB));
      await expectLater(
        transport.readSnapshotInfo(_deviceA),
        throwsA(isA<SyncTransportException>()),
      );
      expect(await transport.readSnapshotInfo(_deviceB), isNull);
    });

    test('blob paths are validated and roundtrip', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      await transport.writeBlob(_deviceA, _sha, bytes);
      expect(io.files[paths.blobPath(_deviceA, _sha)], bytes);
      expect(await transport.readBlob(_deviceA, _sha), bytes);
      expect(await transport.readBlob(_deviceB, _sha), isNull);
      await expectLater(
        transport.writeBlob(_deviceA, '../evil', bytes),
        throwsArgumentError,
      );
    });

    test('deleteDevice removes its directory and state file', () async {
      await transport.writeState(_deviceA, _state(_deviceA));
      await transport.writeChanges(_deviceA, 1, 1, Uint8List.fromList([1]));
      await transport.writeSnapshot(_deviceA, _snapshotBytes(_info(_deviceA)));
      await transport.writeBlob(_deviceA, _sha, Uint8List.fromList([1]));
      await transport.writeState(_deviceB, _state(_deviceB));

      await transport.deleteDevice(_deviceA);
      expect(await transport.readState(_deviceA), isNull);
      expect(await transport.listChanges(_deviceA), isEmpty);
      expect(await transport.readSnapshot(_deviceA), isNull);
      expect(await transport.readBlob(_deviceA, _sha), isNull);
      final devices = await transport.listDevices();
      expect(devices.map((info) => info.deviceId), [_deviceB]);
      expect(io.requestsOf('DELETE-DIR').length, 1);
    });

    test('encodes custom roots in every request path', () async {
      final custom = WebDavSyncTransport.withIo(io, rootPath: 'sync folder/v2');
      await custom.writeState(_deviceA, _state(_deviceA));
      expect(custom.paths.root, 'sync%20folder/v2');
      expect(
        io.files.containsKey('sync%20folder/v2/devices/$_deviceA.json'),
        isTrue,
      );
      expect(await custom.listDevices(), hasLength(1));
    });

    test('maps low level network errors to SyncTransportException', () async {
      io.readError = DioException(
        requestOptions: RequestOptions(path: '/v2/devices/x.json'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/v2/devices/x.json'),
          statusCode: 500,
        ),
        type: DioExceptionType.badResponse,
      );
      await expectLater(
        transport.readState(_deviceA),
        throwsA(
          isA<SyncTransportException>().having(
            (error) => error.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
      io.readError = null;
      // Sanity check: transport still works after the failure.
      expect(await transport.readState(_deviceA), isNull);
    });

    test(
      'writeState rejects a mismatched device id and reads empty state as null',
      () async {
        await expectLater(
          transport.writeState(_deviceA, _state(_deviceB)),
          throwsArgumentError,
        );
        io.files[paths.statePath(_deviceA)] = Uint8List(0);
        expect(await transport.readState(_deviceA), isNull);
      },
    );

    test('close is idempotent and rejects further calls', () async {
      await transport.close();
      await transport.close();
      expect(io.closed, isTrue);
      await expectLater(
        transport.listDevices(),
        throwsA(isA<SyncTransportException>()),
      );
    });
  });
}
