import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/blob_sync.dart';
import 'package:venera/sync/fake_transport.dart';
import 'package:venera/sync/transport.dart';

const _deviceA = 'aaaaaaaa-0000-0000-0000-00000000000a';
const _deviceB = 'bbbbbbbb-0000-0000-0000-00000000000b';

/// Counts blob traffic so ledger tests can assert that repeated uploads stay
/// off the network.
class _CountingTransport extends FakeTransport {
  _CountingTransport(super.remote, {required super.label});

  int readBlobCalls = 0;
  int writeBlobCalls = 0;
  int blobExistsCalls = 0;
  bool failBlobExists = false;

  void resetCounters() {
    readBlobCalls = 0;
    writeBlobCalls = 0;
    blobExistsCalls = 0;
  }

  @override
  Future<Uint8List?> readBlob(String deviceId, String sha256) {
    readBlobCalls++;
    return super.readBlob(deviceId, sha256);
  }

  @override
  Future<void> writeBlob(String deviceId, String sha256, Uint8List bytes) {
    writeBlobCalls++;
    return super.writeBlob(deviceId, sha256, bytes);
  }

  @override
  Future<bool> blobExists(String deviceId, String sha256) {
    blobExistsCalls++;
    if (failBlobExists) {
      return Future.error(
        SyncTransportException('probe failed', statusCode: 500),
      );
    }
    return super.blobExists(deviceId, sha256);
  }
}

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

  group('blob ledger', () {
    test('repeated uploads stay off the network', () async {
      final transport = _CountingTransport(remote, label: _deviceA);
      final blobs = BlobSync(transport: transport, localDeviceId: _deviceA);
      final bytes = Uint8List.fromList(utf8.encode('ledger probe'));

      await blobs.upload(bytes);
      expect(transport.writeBlobCalls, 1);
      expect(transport.readBlobCalls, 1);

      await blobs.upload(bytes);
      expect(transport.writeBlobCalls, 1, reason: 'no second write');
      expect(transport.readBlobCalls, 1, reason: 'no existence probe');

      final other = Uint8List.fromList(utf8.encode('other content'));
      await blobs.upload(other);
      expect(transport.writeBlobCalls, 2);
      expect(transport.readBlobCalls, 2);
    });

    test('ledger persists across instances', () async {
      final persisted = <String, int>{};
      final transport = _CountingTransport(remote, label: _deviceA);
      BlobSync blobs() => BlobSync(
        transport: transport,
        localDeviceId: _deviceA,
        ledgerLoader: () async =>
            persisted.isEmpty ? null : Map<String, int>.of(persisted),
        ledgerSaver: (ledger) async {
          persisted
            ..clear()
            ..addAll(ledger);
        },
      );

      final bytes = Uint8List.fromList(utf8.encode('persisted ledger'));
      final sha = await blobs().upload(bytes);
      expect(persisted.keys, contains(sha));

      transport.resetCounters();
      // A fresh instance (e.g. after an app restart) trusts the ledger.
      await blobs().upload(bytes);
      expect(transport.readBlobCalls, 0);
      expect(transport.writeBlobCalls, 0);
    });

    test('reverifyOldest re-uploads blobs the server lost', () async {
      final transport = _CountingTransport(remote, label: _deviceA);
      final blobs = BlobSync(transport: transport, localDeviceId: _deviceA);
      final bytes = Uint8List.fromList(utf8.encode('lost on server'));
      final sha = await blobs.upload(bytes);
      expect(blobs.uploadsSinceLastGc, 1);

      // Manual server-side pruning.
      await transport.deleteBlob(_deviceA, sha);

      // Blob still ledgered: plain upload stays off the network...
      transport.resetCounters();
      await blobs.upload(bytes);
      expect(transport.writeBlobCalls, 0);

      // ...but the amortized re-verify drops the stale entry and the next
      // upload re-sends the content.
      expect(await blobs.reverifyOldest(4), 1);
      transport.resetCounters();
      final uploaded = await blobs.upload(bytes);
      expect(uploaded, sha);
      expect(transport.writeBlobCalls, 1);
      expect(transport.readBlobCalls, 1);
      expect(remote.debugBlobs(_deviceA)[sha], isNotNull);
    });

    test('reverifyOldest probe failures keep entries', () async {
      final transport = _CountingTransport(remote, label: _deviceA);
      final blobs = BlobSync(transport: transport, localDeviceId: _deviceA);
      final bytes = Uint8List.fromList(utf8.encode('probe failure'));
      await blobs.upload(bytes);

      transport.failBlobExists = true;
      expect(await blobs.reverifyOldest(4), 0);

      // The entry survived, so the upload still skips the network.
      transport.resetCounters();
      await blobs.upload(bytes);
      expect(transport.writeBlobCalls, 0);
      expect(transport.readBlobCalls, 0);
    });

    test('upload counter tracks real writes only', () async {
      final transport = _CountingTransport(remote, label: _deviceA);
      final blobs = BlobSync(transport: transport, localDeviceId: _deviceA);
      final bytes = Uint8List.fromList(utf8.encode('counter check'));

      expect(blobs.uploadsSinceLastGc, 0);
      await blobs.upload(bytes);
      expect(blobs.uploadsSinceLastGc, 1);
      await blobs.upload(bytes);
      expect(blobs.uploadsSinceLastGc, 1, reason: 'ledger hit is not a write');

      blobs.resetUploadCounter();
      expect(blobs.uploadsSinceLastGc, 0);
    });

    test('deleteUnreferenced invalidates ledger entries', () async {
      final transport = _CountingTransport(remote, label: _deviceA);
      final blobs = BlobSync(transport: transport, localDeviceId: _deviceA);
      final bytes = Uint8List.fromList(utf8.encode('gc then re-add'));
      final sha = await blobs.upload(bytes);
      expect(transport.writeBlobCalls, 1);

      // The record died; the sweep deletes the blob and must drop the
      // ledger claim that it is present.
      await blobs.deleteUnreferenced(const <String>{});
      expect(remote.debugBlobs(_deviceA)[sha], isNull);

      // Re-adding the same content must actually re-upload it.
      transport.resetCounters();
      final again = await blobs.upload(bytes);
      expect(again, sha);
      expect(
        transport.writeBlobCalls,
        1,
        reason: 'stale ledger entry must not skip the re-upload',
      );
      expect(remote.debugBlobs(_deviceA)[sha], isNotNull);
    });
  });
}
