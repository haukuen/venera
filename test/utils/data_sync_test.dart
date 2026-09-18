import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  group('DataSyncStatusSnapshot', () {
    test('hides sync card when WebDAV is disabled and there is no error', () {
      const status = DataSyncStatusSnapshot(
        isEnabled: false,
        isUploading: false,
        isDownloading: false,
        lastSyncTime: 0,
        lastError: null,
      );

      expect(status.shouldShow, isFalse);
    });

    test(
      'shows upload progress before stale error or last sync information',
      () {
        const status = DataSyncStatusSnapshot(
          isEnabled: true,
          isUploading: true,
          isDownloading: false,
          lastSyncTime: 1710000000000,
          lastError: 'old error',
        );

        expect(status.shouldShow, isTrue);
        expect(status.title, 'Syncing Data');
        expect(status.isSyncing, isTrue);
      },
    );

    test('shows download progress as a syncing state', () {
      const status = DataSyncStatusSnapshot(
        isEnabled: true,
        isUploading: false,
        isDownloading: true,
        lastSyncTime: 0,
        lastError: null,
      );

      expect(status.shouldShow, isTrue);
      expect(status.title, 'Syncing Data');
      expect(status.isSyncing, isTrue);
    });

    test('hides stale sync errors after WebDAV is disabled', () {
      const status = DataSyncStatusSnapshot(
        isEnabled: false,
        isUploading: false,
        isDownloading: false,
        lastSyncTime: 0,
        lastError: 'connection refused',
      );

      expect(status.shouldShow, isFalse);
    });

    test('formats last successful sync time when idle', () {
      final timestamp = DateTime(2024, 3, 10, 9, 8).millisecondsSinceEpoch;
      final status = DataSyncStatusSnapshot(
        isEnabled: true,
        isUploading: false,
        isDownloading: false,
        lastSyncTime: timestamp,
        lastError: null,
      );

      expect(status.title, 'Sync Data');
      expect(status.formattedLastSyncTime, '2024-03-10 09:08');
    });

    test('shows a clear idle state before the first successful sync', () {
      const status = DataSyncStatusSnapshot(
        isEnabled: true,
        isUploading: false,
        isDownloading: false,
        lastSyncTime: 0,
        lastError: null,
      );

      expect(status.shouldShow, isTrue);
      expect(status.isSyncing, isFalse);
    });
  });

  group('WebDavConnectionTester', () {
    test(
      'rejects invalid WebDAV configuration without probing network',
      () async {
        var probeCalls = 0;

        final result = await WebDavConnectionTester.test(
          const ['https://example.com/webdav', 'user'],
          probe: (_) async {
            probeCalls++;
          },
        );

        expect(result.error, isTrue);
        expect(result.errorMessage, 'Invalid WebDAV configuration');
        expect(probeCalls, 0);
      },
    );

    test('returns success when the WebDAV probe succeeds', () async {
      List<String>? probedConfig;

      final result = await WebDavConnectionTester.test(
        const ['https://example.com/webdav', 'user', 'pass'],
        probe: (config) async {
          probedConfig = config;
        },
      );

      expect(result.success, isTrue);
      expect(probedConfig, const [
        'https://example.com/webdav',
        'user',
        'pass',
      ]);
    });

    test('allows empty credentials for anonymous WebDAV servers', () async {
      List<String>? probedConfig;

      final result = await WebDavConnectionTester.test(
        const ['https://example.com/webdav', '', ''],
        probe: (config) async {
          probedConfig = config;
        },
      );

      expect(result.success, isTrue);
      expect(probedConfig, const ['https://example.com/webdav', '', '']);
    });

    test('returns the probe error message when connection fails', () async {
      final result = await WebDavConnectionTester.test(
        const ['https://example.com/webdav', 'user', 'pass'],
        probe: (_) async {
          throw Exception('401 Unauthorized');
        },
      );

      expect(result.error, isTrue);
      expect(result.errorMessage, contains('401 Unauthorized'));
    });
  });

  group('DataSync transfer authorization', () {
    late Object? previousConfig;
    late bool hadAutoSyncSetting;
    late Object? previousAutoSync;

    setUp(() {
      previousConfig = appdata.settings['webdav'];
      hadAutoSyncSetting = appdata.implicitData.containsKey('webdavAutoSync');
      previousAutoSync = appdata.implicitData['webdavAutoSync'];
    });

    tearDown(() {
      appdata.settings['webdav'] = previousConfig;
      if (hadAutoSyncSetting) {
        appdata.implicitData['webdavAutoSync'] = previousAutoSync;
      } else {
        appdata.implicitData.remove('webdavAutoSync');
      }
    });

    test('skips automatic transfers when Auto Sync is disabled', () async {
      appdata.settings['webdav'] = const ['invalid'];
      appdata.implicitData['webdavAutoSync'] = false;
      final sync = DataSync.forTesting();

      final upload = await sync.uploadData();
      final download = await sync.downloadData();

      expect(upload.success, isTrue);
      expect(download.success, isTrue);
      expect(sync.isUploading, isFalse);
      expect(sync.isDownloading, isFalse);
      expect(sync.lastError, isNull);
    });

    test('keeps explicit manual transfers available when disabled', () async {
      appdata.settings['webdav'] = const ['invalid'];
      appdata.implicitData['webdavAutoSync'] = false;
      final sync = DataSync.forTesting();

      final upload = await sync.uploadDataManually();
      final download = await sync.downloadDataManually();

      expect(upload.error, isTrue);
      expect(upload.errorMessage, 'Invalid WebDAV configuration');
      expect(download.error, isTrue);
      expect(download.errorMessage, 'Invalid WebDAV configuration');
    });
  });
}
