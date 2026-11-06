import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/app/adapters/comic_source_data_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/blob_sync.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/fake_transport.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
const _deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';

String shaOf(String content) =>
    BlobSync.sha256Hex(Uint8List.fromList(utf8.encode(content)));

void main() {
  late Directory root;
  late Directory dirA;
  late Directory dirB;
  late FakeRemote remote;
  late FakeTransport transportA;
  late FakeTransport transportB;
  late BlobSync blobSyncA;
  late BlobSync blobSyncB;
  late SqliteSyncStore store;
  late List<String> warnings;
  late int reloadCalls;
  late ComicSourceDataAdapter adapterA;
  late ComicSourceDataAdapter adapterB;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('venera-source-data-');
    dirA = Directory('${root.path}/a')..createSync(recursive: true);
    dirB = Directory('${root.path}/b');

    remote = FakeRemote();
    transportA = FakeTransport(remote, label: 'A');
    transportB = FakeTransport(remote, label: 'B');
    blobSyncA = BlobSync(transport: transportA, localDeviceId: _deviceA);
    blobSyncB = BlobSync(transport: transportB, localDeviceId: _deviceB);
    store = await SqliteSyncStore.open(
      dbPath: '${root.path}/sync.db',
      deviceId: _deviceA,
    );
    warnings = <String>[];
    reloadCalls = 0;
    adapterA = ComicSourceDataAdapter(
      sourceDir: dirA.path,
      blobSync: blobSyncA,
      onWarning: warnings.add,
    );
    adapterB = ComicSourceDataAdapter(
      sourceDir: dirB.path,
      blobSync: blobSyncB,
      reload: () async {
        reloadCalls++;
      },
      onWarning: warnings.add,
    );
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File writeData(Directory dir, String name, String content) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file;
  }

  File dataFile(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  Future<void> emitRecords(Iterable<AdapterRecord> records) async {
    for (final record in records) {
      await store.emit(
        domain: record.domain,
        key: record.key,
        field: record.field,
        kind: record.kind,
        data: record.data,
      );
    }
  }

  test('projects .data files as auth blob references', () async {
    writeData(dirA, 'a.data', '{"token":"t1"}');
    writeData(dirA, 'b.data', '{"uid":42}');
    writeData(dirA, 'broken.data', 'not json');
    writeData(dirA, 'empty.data', '');
    writeData(dirA, 'notes.txt', 'ignored');

    final records = await adapterA.readLocalRecords();

    expect(records, hasLength(2));
    expect(records.map((record) => record.key.parts), <List<String>>[
      <String>['@sourceData', 'a'],
      <String>['@sourceData', 'b'],
    ]);
    for (final record in records) {
      expect(record.domain, SyncDomains.auth);
      expect(record.field, '');
      expect(record.kind, SyncOpKind.upsert);
    }
    expect((records.first.data!['sha256']), shaOf('{"token":"t1"}'));
    expect(records.first.data!['size'], utf8.encode('{"token":"t1"}').length);
    // Reading only hashes files; no blob is uploaded here.
    expect(remote.requestCount, 0);
    expect(warnings, hasLength(2));
  });

  test('missing directory yields no records', () async {
    final adapter = ComicSourceDataAdapter(
      sourceDir: '${root.path}/missing',
      blobSync: blobSyncA,
    );
    expect(await adapter.readLocalRecords(), isEmpty);
    await adapter.ensureBlobsUploaded();
    expect(warnings, isEmpty);
  });

  test('uploads every valid .data blob', () async {
    writeData(dirA, 'a.data', '{"token":"t1"}');
    writeData(dirA, 'b.data', '{"x":2}');
    writeData(dirA, 'broken.data', '{oops');

    await adapterA.ensureBlobsUploaded();

    final blobs = remote.debugBlobs(_deviceA);
    expect(
      blobs.keys,
      unorderedEquals(<String>[shaOf('{"token":"t1"}'), shaOf('{"x":2}')]),
    );
    expect(utf8.decode(blobs[shaOf('{"token":"t1"}')]!), '{"token":"t1"}');
  });

  test('roundtrips login state to the second device', () async {
    writeData(dirA, 'picacg.data', '{"token":"abc","account":["u","p"]}');
    await adapterA.ensureBlobsUploaded();
    await emitRecords(await adapterA.readLocalRecords());

    await adapterB.applyRemote(store);

    expect(
      dataFile(dirB, 'picacg.data').readAsStringSync(),
      '{"token":"abc","account":["u","p"]}',
    );
    expect(reloadCalls, 1);
    expect(warnings, isEmpty);

    // A second apply is a no-op.
    await adapterB.applyRemote(store);
    expect(reloadCalls, 1);
  });

  test('tombstone deletes the local source data', () async {
    writeData(dirB, 'jm.data', '{"uid":1}');
    final key = SyncKeys.sourceDataKey('jm');
    await store.emit(
      domain: SyncDomains.auth,
      key: key,
      kind: SyncOpKind.upsert,
      data: {'sha256': shaOf('{}'), 'size': 2},
    );
    await store.emit(domain: SyncDomains.auth, key: key, kind: SyncOpKind.del);

    await adapterB.applyRemote(store);

    expect(dataFile(dirB, 'jm.data').existsSync(), isFalse);
    expect(reloadCalls, 1);
  });

  test('keeps local data when the referenced blob is missing', () async {
    writeData(dirB, 'komga.data', '{"komga_auth":"local"}');
    await store.emit(
      domain: SyncDomains.auth,
      key: SyncKeys.sourceDataKey('komga'),
      kind: SyncOpKind.upsert,
      data: {'sha256': shaOf('{"komga_auth":"remote"}'), 'size': 24},
    );

    await adapterB.applyRemote(store);

    expect(
      dataFile(dirB, 'komga.data').readAsStringSync(),
      '{"komga_auth":"local"}',
    );
    expect(reloadCalls, 0);
    expect(warnings, hasLength(1));
  });

  test('ignores cookie records without warnings', () async {
    await store.emit(
      domain: SyncDomains.auth,
      key: SyncKeys.authCookieKey('example.com', '/', 'sid'),
      kind: SyncOpKind.upsert,
      data: {'value': 'v', 'expires': null, 'secure': 0, 'httpOnly': 0},
    );

    await adapterB.applyRemote(store);

    expect(warnings, isEmpty);
    expect(dirB.existsSync(), isFalse);
    expect(reloadCalls, 0);
  });

  test('source-data keys and cookie keys cannot collide', () {
    final cookie = SyncKeys.authCookieKey('example.com', '/', 'sid').parts;
    final sourceData = SyncKeys.sourceDataKey('picacg').parts;
    expect(SyncKeys.isSourceDataKey(cookie), isFalse);
    expect(SyncKeys.isSourceDataKey(sourceData), isTrue);
    expect(sourceData, <String>['@sourceData', 'picacg']);
  });

  test('skips corrupt remote payloads and keeps the local file', () async {
    writeData(dirB, 'ccc.data', '{"token":"local"}');
    const corrupt = 'not-json';
    await transportA.writeBlob(
      _deviceA,
      shaOf(corrupt),
      Uint8List.fromList(utf8.encode(corrupt)),
    );
    await store.emit(
      domain: SyncDomains.auth,
      key: SyncKeys.sourceDataKey('ccc'),
      kind: SyncOpKind.upsert,
      data: {'sha256': shaOf(corrupt), 'size': corrupt.length},
    );

    await adapterB.applyRemote(store);

    expect(dataFile(dirB, 'ccc.data').readAsStringSync(), '{"token":"local"}');
    expect(warnings, hasLength(1));
    expect(reloadCalls, 0);
  });

  test('unsafe source keys never escape the source directory', () async {
    writeData(dirB, 'safe.data', '{"a":1}');
    await transportA.writeBlob(
      _deviceA,
      shaOf('{}'),
      Uint8List.fromList(utf8.encode('{}')),
    );
    for (final stem in <String>['..', 'a/b', r'a\b', '']) {
      await store.emit(
        domain: SyncDomains.auth,
        key: SyncKeys.sourceDataKey(stem),
        kind: SyncOpKind.upsert,
        data: {'sha256': shaOf('{}'), 'size': 2},
      );
    }

    await adapterB.applyRemote(store);

    expect(File('${root.path}/..data').existsSync(), isFalse);
    expect(File('${root.path}/a/b.data').existsSync(), isFalse);
    expect(dataFile(dirB, '.data').existsSync(), isFalse);
    expect(warnings, hasLength(4));
    expect(reloadCalls, 0);
  });
}
