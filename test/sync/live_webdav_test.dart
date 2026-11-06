/// Live WebDAV end-to-end smoke test (opt-in, skipped by default).
///
/// Configure a *dedicated test directory* (never production data):
///
///   VENERA_SYNC_WEBDAV_URL=https://example.com/dav/test-venera/
///   VENERA_SYNC_WEBDAV_USER=...
///   VENERA_SYNC_WEBDAV_PASS=...
///   # optional:
///   VENERA_SYNC_WEBDAV_INSECURE=1        # self-signed TLS
///   VENERA_SYNC_WEBDAV_PROXY=http://host:port   # plain HTTP proxy
///   VENERA_SYNC_WEBDAV_ROOT=venera-sync-live-ID  # unique remote root
///
/// Then:
///   flutter test test/sync/live_webdav_test.dart
///
/// The test creates three virtual devices under the remote root, exercises
/// push/pull, snapshot + GC + bootstrap, deletion, and finally removes the
/// device branches it created. The shared schema file and the root directory
/// itself are left behind (the transport contract has no "delete root").
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/sync.dart';
import 'package:venera/sync/webdav_transport.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

const _deviceA = 'aaaaaaaa-0000-0000-0000-0000000000aa';
const _deviceB = 'bbbbbbbb-0000-0000-0000-0000000000bb';
const _deviceC = 'cccccccc-0000-0000-0000-0000000000cc';

void main() {
  final url = Platform.environment['VENERA_SYNC_WEBDAV_URL']?.trim();
  final user = Platform.environment['VENERA_SYNC_WEBDAV_USER'] ?? '';
  final password = Platform.environment['VENERA_SYNC_WEBDAV_PASS'] ?? '';
  final insecure =
      Platform.environment['VENERA_SYNC_WEBDAV_INSECURE'] == '1' ||
      Platform.environment['VENERA_SYNC_WEBDAV_INSECURE'] == 'true';
  final proxy = Platform.environment['VENERA_SYNC_WEBDAV_PROXY']?.trim();
  final rootPath =
      Platform.environment['VENERA_SYNC_WEBDAV_ROOT']?.trim().isNotEmpty == true
      ? Platform.environment['VENERA_SYNC_WEBDAV_ROOT']!.trim()
      : 'venera-sync-live-${DateTime.now().millisecondsSinceEpoch}';

  webdav.Client clientFactory(String baseUrl, String userName, String pass) {
    final adapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        if (insecure) {
          client.badCertificateCallback = (cert, host, port) => true;
        }
        final proxyValue = proxy;
        if (proxyValue != null && proxyValue.isNotEmpty) {
          final proxyUri = Uri.parse(proxyValue);
          client.findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}';
        }
        return client;
      },
    );
    return webdav.newClient(
      baseUrl,
      user: userName,
      password: pass,
      adapter: adapter,
    );
  }

  test(
    'live WebDAV: push/pull, snapshot bootstrap, deletion, cleanup',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('venera_live_dav_');
      final stores = <SqliteSyncStore>[];
      final engines = <SyncEngine>[];
      final transports = <WebDavSyncTransport>[];
      final opened = <String>[];

      Future<(SqliteSyncStore, WebDavSyncTransport, SyncEngine)> openDevice(
        String deviceId,
      ) async {
        final store = await SqliteSyncStore.open(
          dbPath: '${tempDir.path}/$deviceId.db',
          deviceId: deviceId,
        );
        final transport = WebDavSyncTransport.connect(
          baseUrl: url!,
          user: user,
          password: password,
          clientFactory: clientFactory,
          rootPath: rootPath,
        );
        final engine = SyncEngine(
          store: store,
          transport: transport,
          enabledDomains: SyncDomains.enabledDomains(syncAuthEnabled: false),
        );
        await engine.init();
        stores.add(store);
        engines.add(engine);
        transports.add(transport);
        opened.add(deviceId);
        return (store, transport, engine);
      }

      try {
        final (storeA, transportA, engineA) = await openDevice(_deviceA);

        // Shared schema document; writes create device directories lazily.
        final schema = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'protocol': 2,
              'schema': 2,
              'domains': SyncDomains.all.toList()..sort(),
            }),
          ),
        );
        await transportA.ensureSchema(schema);

        final key = SyncKeys.historyKey('live-comic', '1');
        Future<void> writeProgress(
          SqliteSyncStore store,
          int ep, {
          int page = 0,
        }) async {
          await store.emit(
            domain: SyncDomains.history,
            key: key,
            field: SyncFields.progress,
            kind: SyncOpKind.upsert,
            data: {
              'ep': ep,
              'page': page,
              'time': DateTime.now().millisecondsSinceEpoch,
            },
          );
        }

        Future<Map<String, Object?>?> readProgress(
          SqliteSyncStore store,
        ) async {
          final record = await store.recordOf(
            SyncDomains.history,
            key,
            SyncFields.progress,
          );
          return record?.data;
        }

        await writeProgress(storeA, 12);
        final pushA = await engineA.push();
        expect(
          pushA.success,
          isTrue,
          reason: 'first push failed: ${pushA.error}',
        );
        expect(pushA.opsPushed, 1);

        final (storeB, _, engineB) = await openDevice(_deviceB);
        final pullB = await engineB.pull();
        expect(pullB.errors, isEmpty, reason: 'pull errors: ${pullB.errors}');
        expect((await readProgress(storeB))?['ep'], 12);

        // Periodic snapshot + GC + fresh device bootstrap.
        final snapshot = await engineA.snapshot();
        expect(
          snapshot.written,
          isTrue,
          reason: 'snapshot failed: ${snapshot.error}',
        );
        final gc = await engineA.gc();
        expect(gc.error, isNull);
        expect(gc.deletedUpTo, greaterThanOrEqualTo(1));

        final (storeC, _, engineC) = await openDevice(_deviceC);
        final pullC = await engineC.pull();
        expect(
          pullC.errors,
          isEmpty,
          reason: 'bootstrap errors: ${pullC.errors}',
        );
        expect(pullC.snapshotsApplied, greaterThanOrEqualTo(1));
        expect((await readProgress(storeC))?['ep'], 12);

        // Deletion propagates.
        await storeA.emit(
          domain: SyncDomains.history,
          key: key,
          field: SyncFields.progress,
          kind: SyncOpKind.del,
        );
        await engineA.push();
        await engineB.pull();
        final deleted = await storeB.recordOf(
          SyncDomains.history,
          key,
          SyncFields.progress,
        );
        expect(deleted, isNotNull);
        expect(deleted!.visible, isFalse);
      } finally {
        for (final deviceId in opened) {
          try {
            await transports.first.deleteDevice(deviceId);
          } catch (_) {
            // Best effort cleanup; keep the original failure visible.
          }
        }
        for (final engine in engines) {
          try {
            await engine.close();
          } catch (_) {}
        }
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    },
    skip: (url == null || url.isEmpty)
        ? 'Set VENERA_SYNC_WEBDAV_URL (and USER/PASS) to run the live WebDAV test'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
