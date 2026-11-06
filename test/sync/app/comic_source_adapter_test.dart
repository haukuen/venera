import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/app/adapters/comic_source_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/blob_sync.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/fake_transport.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
const _deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';

String shaOf(String content) =>
    BlobSync.sha256Hex(Uint8List.fromList(utf8.encode(content)));

void main() {
  late Directory root;
  late Directory sourceDirA;
  late Directory sourceDirB;
  late FakeRemote remote;
  late FakeTransport transportA;
  late FakeTransport transportB;
  late BlobSync blobSyncA;
  late BlobSync blobSyncB;
  late SqliteSyncStore store;
  late List<String> warnings;
  late int reloadCalls;
  late ComicSourceAdapter adapterA;
  late ComicSourceAdapter adapterB;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('venera-comic-source-');
    sourceDirA = Directory('${root.path}/a');
    sourceDirB = Directory('${root.path}/b');
    sourceDirA.createSync(recursive: true);

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
    adapterA = ComicSourceAdapter(
      sourceDir: sourceDirA.path,
      blobSync: blobSyncA,
      onWarning: warnings.add,
    );
    adapterB = ComicSourceAdapter(
      sourceDir: sourceDirB.path,
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

  File writeSource(Directory dir, String name, String content) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file;
  }

  File sourceFile(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  Future<void> emitSource(
    String stem, {
    String? sha256,
    List<String>? parts,
    String field = '',
    Map<String, Object?>? data,
    bool deleted = false,
  }) async {
    final key = SyncKey(parts ?? <String>[stem]);
    await store.emit(
      domain: SyncDomains.comicSource,
      key: key,
      field: field,
      kind: SyncOpKind.upsert,
      data:
          data ??
          <String, Object?>{'sha256': sha256, 'size': 0, 'name': '$stem.js'},
    );
    if (deleted) {
      await store.emit(
        domain: SyncDomains.comicSource,
        key: key,
        field: field,
        kind: SyncOpKind.del,
      );
    }
  }

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

  group('readLocalRecords', () {
    test(
      'projects js files with sha256/size/name and ignores other files',
      () async {
        const contentA = '// source a\nComicSource({ key: "a" });';
        const contentB = '// source b\nComicSource({ key: "b" });';
        writeSource(sourceDirA, 'a.js', contentA);
        writeSource(sourceDirA, 'b.js', contentB);
        writeSource(sourceDirA, 'a.data', '{"cache":1}');
        writeSource(Directory('${sourceDirA.path}/nested'), 'nested.js', 'x');

        final records = await adapterA.readLocalRecords();

        expect(records, hasLength(2));
        expect(records.map((record) => record.key.parts.single), <String>[
          'a',
          'b',
        ]);
        for (final record in records) {
          expect(record.domain, SyncDomains.comicSource);
          expect(record.field, '');
          expect(record.kind, SyncOpKind.upsert);
        }
        final first = records.first;
        expect(first.key.parts, <String>['a']);
        expect(first.data, <String, Object?>{
          'sha256': shaOf(contentA),
          'size': utf8.encode(contentA).length,
          'name': 'a.js',
        });
        // Reading must never touch the transport (blobs are uploaded later).
        expect(remote.requestCount, 0);
        expect(remote.debugBlobs(_deviceA), isEmpty);
      },
    );

    test('missing source directory yields no records', () async {
      final adapter = ComicSourceAdapter(
        sourceDir: '${root.path}/does-not-exist',
        blobSync: blobSyncA,
      );

      expect(await adapter.readLocalRecords(), isEmpty);
    });
  });

  group('ensureBlobsUploaded', () {
    test('uploads every js file to the device blob branch', () async {
      const contentA = 'var a = 1;';
      const contentB = 'var b = 2;';
      writeSource(sourceDirA, 'a.js', contentA);
      writeSource(sourceDirA, 'b.js', contentB);

      await adapterA.ensureBlobsUploaded();

      final blobs = remote.debugBlobs(_deviceA);
      expect(
        blobs.keys,
        unorderedEquals(<String>[shaOf(contentA), shaOf(contentB)]),
      );
      expect(utf8.decode(blobs[shaOf(contentA)]!), contentA);

      // Re-uploading is idempotent: no additional writeBlob requests.
      final writeCountBefore = remote.log
          .where((entry) => entry.contains('writeBlob'))
          .length;
      await adapterA.ensureBlobsUploaded();
      final writeCountAfter = remote.log
          .where((entry) => entry.contains('writeBlob'))
          .length;
      expect(writeCountAfter, writeCountBefore);
    });
  });

  group('applyRemote', () {
    test('writes files on the second device and reloads once', () async {
      const contentA = 'var a = "from A";';
      const contentB = 'var b = "from B";';
      writeSource(sourceDirA, 'a.js', contentA);
      writeSource(sourceDirA, 'b.js', contentB);
      await adapterA.ensureBlobsUploaded();
      await emitRecords(await adapterA.readLocalRecords());

      await adapterB.applyRemote(store);

      expect(sourceFile(sourceDirB, 'a.js').readAsStringSync(), contentA);
      expect(sourceFile(sourceDirB, 'b.js').readAsStringSync(), contentB);
      expect(reloadCalls, 1);
      expect(warnings, isEmpty);

      // A second apply with unchanged content is a no-op.
      await adapterB.applyRemote(store);
      expect(reloadCalls, 1);
    });

    test(
      'deletes files whose key is not visible, keeps .data and dirs',
      () async {
        writeSource(sourceDirB, 'stale.js', 'stale');
        writeSource(sourceDirB, 'notes.data', 'keep me');
        writeSource(Directory('${sourceDirB.path}/nested'), 'inside.js', 'x');
        const content = 'var keep = 1;';
        writeSource(sourceDirA, 'keep.js', content);
        await adapterA.ensureBlobsUploaded();
        await emitRecords(await adapterA.readLocalRecords());

        await adapterB.applyRemote(store);

        expect(sourceFile(sourceDirB, 'keep.js').readAsStringSync(), content);
        expect(sourceFile(sourceDirB, 'stale.js').existsSync(), isFalse);
        expect(
          sourceFile(sourceDirB, 'notes.data').readAsStringSync(),
          'keep me',
        );
        expect(
          sourceFile(
            Directory('${sourceDirB.path}/nested'),
            'inside.js',
          ).existsSync(),
          isTrue,
        );
        expect(reloadCalls, 1);
      },
    );

    test('tombstoned records delete the local file', () async {
      writeSource(sourceDirB, 'gone.js', 'old');
      const content = 'var keep = 1;';
      writeSource(sourceDirA, 'keep.js', content);
      await adapterA.ensureBlobsUploaded();
      await emitRecords(await adapterA.readLocalRecords());
      await emitSource('gone', sha256: shaOf('old'), deleted: true);

      await adapterB.applyRemote(store);

      expect(sourceFile(sourceDirB, 'gone.js').existsSync(), isFalse);
      expect(sourceFile(sourceDirB, 'keep.js').readAsStringSync(), content);
      expect(reloadCalls, 1);
      expect(warnings, isEmpty);
    });

    test(
      'missing blobs are tolerated with warnings and keep local files',
      () async {
        writeSource(sourceDirB, 'legacy.js', 'old local copy');
        await emitSource('legacy', sha256: shaOf('never uploaded legacy'));
        await emitSource('brandNew', sha256: shaOf('never uploaded new'));

        await adapterB.applyRemote(store);

        expect(warnings, hasLength(2));
        expect(
          sourceFile(sourceDirB, 'legacy.js').readAsStringSync(),
          'old local copy',
        );
        expect(sourceFile(sourceDirB, 'brandNew.js').existsSync(), isFalse);
        // Nothing was written/deleted, so no reload.
        expect(reloadCalls, 0);
      },
    );

    test('tampered blobs are rejected with a warning', () async {
      const content = 'var genuine = 1;';
      final sha256 = shaOf(content);
      await transportA.writeBlob(
        _deviceA,
        sha256,
        Uint8List.fromList(utf8.encode('tampered bytes')),
      );
      await emitSource('tampered', sha256: sha256);

      await adapterB.applyRemote(store);

      expect(warnings, hasLength(1));
      expect(sourceFile(sourceDirB, 'tampered.js').existsSync(), isFalse);
      expect(reloadCalls, 0);
    });

    test(
      'rejects unsafe keys and never escapes the source directory',
      () async {
        const content = 'var good = 1;';
        writeSource(sourceDirA, 'good.js', content);
        await adapterA.ensureBlobsUploaded();
        final sha256 = shaOf(content);
        await emitSource('good', sha256: sha256);
        await emitSource('..', sha256: sha256);
        await emitSource('a/b', sha256: sha256);
        await emitSource(r'a\b', sha256: sha256);
        await emitSource('', sha256: sha256, parts: <String>['x', 'y']);

        await adapterB.applyRemote(store);

        expect(sourceFile(sourceDirB, 'good.js').readAsStringSync(), content);
        expect(sourceFile(sourceDirB, '..js').existsSync(), isFalse);
        expect(File('${root.path}/evil.js').existsSync(), isFalse);
        expect(File('${root.path}/a/b.js').existsSync(), isFalse);
        expect(warnings, hasLength(4));
        expect(reloadCalls, 1);
      },
    );

    test(
      'read -> upload -> apply roundtrips between two source dirs',
      () async {
        const contentA = 'var a = 1;';
        const contentB = 'var b = 2;';
        writeSource(sourceDirA, 'a.js', contentA);
        writeSource(sourceDirA, 'b.js', contentB);
        await adapterA.ensureBlobsUploaded();
        await emitRecords(await adapterA.readLocalRecords());
        final sourceRecords = await adapterA.readLocalRecords();

        await adapterB.applyRemote(store);

        final targetRecords = await adapterB.readLocalRecords();
        String describe(Iterable<AdapterRecord> records) {
          final entries = records.toList()
            ..sort((a, b) => a.key.encode().compareTo(b.key.encode()));
          return entries
              .map((record) => '${record.key.encode()}|${record.data}')
              .join('\n');
        }

        expect(describe(targetRecords), describe(sourceRecords));
      },
    );

    test('reload() invokes the injected callback', () async {
      await adapterB.reload();

      expect(reloadCalls, 1);
    });
  });
}
