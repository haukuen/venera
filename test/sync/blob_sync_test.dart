import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/blob_sync.dart';
import 'package:venera/sync/fake_transport.dart';
import 'package:venera/sync/transport.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';
const _deviceB = 'bbbbbbbb-0000-0000-0000-00000000000b';

void main() {
  late FakeRemote remote;
  late FakeTransport transportA;
  late FakeTransport transportB;
  late BlobSync blobsA;
  late BlobSync blobsB;

  setUp(() {
    remote = FakeRemote();
    transportA = FakeTransport(remote, label: _deviceA);
    transportB = FakeTransport(remote, label: _deviceB);
    blobsA = BlobSync(transport: transportA, localDeviceId: _deviceA);
    blobsB = BlobSync(transport: transportB, localDeviceId: _deviceB);
  });

  test('sha256 is stable and validated', () {
    final bytes = Uint8List.fromList(utf8.encode('console.log(1);'));
    final sha = BlobSync.sha256Hex(bytes);
    expect(sha, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(sha), isTrue);
    expect(() => BlobSync.validateSha256('nope'), throwsArgumentError);
  });

  test('upload is idempotent and download verifies content', () async {
    final bytes = Uint8List.fromList(utf8.encode('source code'));
    final sha = await blobsA.upload(bytes);
    expect(remote.debugBlobs(_deviceA)[sha], isNotNull);

    // Second upload must not create a duplicate/fail.
    expect(await blobsA.upload(bytes), sha);
    expect(remote.debugBlobs(_deviceA).length, 1);

    final downloaded = await blobsB.download(sha, fromDevice: _deviceA);
    expect(downloaded, isNotNull);
    expect(utf8.decode(downloaded!), 'source code');
  });

  test('download from unknown device and unknown sha returns null', () async {
    final sha = BlobSync.sha256Hex(Uint8List.fromList([1, 2, 3]));
    expect(await blobsB.download(sha, fromDevice: _deviceA), isNull);

    final otherSha = BlobSync.sha256Hex(Uint8List.fromList([4, 5, 6]));
    await blobsA.upload(Uint8List.fromList([1, 2, 3]));
    expect(await blobsB.download(otherSha, fromDevice: _deviceA), isNull);
  });

  test('download detects corrupted remote bytes', () async {
    final bytes = Uint8List.fromList(utf8.encode('original'));
    final sha = await blobsA.upload(bytes);
    // Tamper with the stored bytes while keeping the sha-addressed name.
    final stored = remote.debugBlobs(_deviceA)[sha]!;
    stored[0] = stored[0] ^ 0xff;

    expect(
      () => blobsB.download(sha, fromDevice: _deviceA),
      throwsA(isA<SyncTransportException>()),
    );
  });

  test('downloadFromAnyDevice searches device branches', () async {
    final bytes = Uint8List.fromList(utf8.encode('search me'));
    final sha = await blobsA.upload(bytes);

    final found = await blobsB.downloadFromAnyDevice(sha);
    expect(found, isNotNull);
    expect(utf8.decode(found!), 'search me');

    final missing = BlobSync.sha256Hex(Uint8List.fromList([9, 9, 9]));
    expect(await blobsB.downloadFromAnyDevice(missing), isNull);
  });

  test('rejects invalid device ids and shas', () {
    expect(
      () => BlobSync(transport: transportA, localDeviceId: '../evil'),
      throwsArgumentError,
    );
    expect(
      () => blobsA.download('NOT-A-SHA', fromDevice: _deviceA),
      throwsArgumentError,
    );
    expect(
      () => blobsA.download(
        BlobSync.sha256Hex(Uint8List.fromList([1])),
        fromDevice: '../evil',
      ),
      throwsArgumentError,
    );
  });

  test('deleteUnreferenced removes only unreferenced blobs', () async {
    final keepSha = await blobsA.upload(
      Uint8List.fromList(utf8.encode('keep me')),
    );
    await blobsA.upload(Uint8List.fromList(utf8.encode('garbage')));

    final deleted = await blobsA.deleteUnreferenced({keepSha});

    expect(deleted, 1);
    final remaining = remote.debugBlobs(_deviceA);
    expect(remaining.keys, <String>[keepSha]);

    // A later re-upload of removed content is a plain re-create.
    final again = await blobsA.upload(
      Uint8List.fromList(utf8.encode('garbage')),
    );
    expect(again, isNotNull);
  });

  test('deleteUnreferenced survives list failures', () async {
    await blobsA.upload(Uint8List.fromList(utf8.encode('orphan')));
    remote.setUnavailable(true);

    final deleted = await blobsA.deleteUnreferenced(const <String>{});

    expect(deleted, 0);
    expect(remote.debugBlobs(_deviceA), isNotEmpty);
  });
}
