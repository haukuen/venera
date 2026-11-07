import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/app/adapters/settings_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceId = 'aaaaaaaa-1111-2222-3333-444444444444';

/// A settings map plus the callbacks the adapter needs, mirroring how the app
/// wires `appdata.settings` / `appdata.saveData`.
class _Harness {
  _Harness([Map<String, Object?>? initial]) {
    if (initial != null) values.addAll(initial);
  }

  final Map<String, Object?> values = <String, Object?>{};
  final List<String> warnings = <String>[];
  int persistCalls = 0;
  int reloadCalls = 0;

  late final SettingsAdapter adapter = SettingsAdapter(
    keys: () => values.keys.toSet(),
    get: (key) => values[key],
    set: (key, value) => values[key] = value,
    persist: () async {
      persistCalls++;
    },
    reload: () async {
      reloadCalls++;
    },
    onWarning: warnings.add,
  );
}

void main() {
  late Directory dir;
  late SqliteSyncStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('venera-settings-adapter-');
    store = await SqliteSyncStore.open(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceId,
    );
  });

  tearDown(() async {
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> emitSetting(
    String key,
    Object? value, {
    String field = '',
    List<String>? parts,
    Map<String, Object?>? data,
  }) async {
    await store.emit(
      domain: SyncDomains.setting,
      key: SyncKey(parts ?? <String>[key]),
      field: field,
      kind: SyncOpKind.upsert,
      data: data ?? <String, Object?>{'value': value},
    );
  }

  Future<void> tombstoneSetting(List<String> parts) async {
    final key = SyncKey(parts);
    await store.emit(
      domain: SyncDomains.setting,
      key: key,
      kind: SyncOpKind.upsert,
      data: const <String, Object?>{'value': 'gone'},
    );
    await store.emit(
      domain: SyncDomains.setting,
      key: key,
      kind: SyncOpKind.del,
    );
  }

  group('readLocalRecords', () {
    test(
      'projects syncable settings and skips device-local/null values',
      () async {
        final harness = _Harness(<String, Object?>{
          'theme_mode': 'dark',
          'cacheSize': 2048,
          'explore_pages': <int>[1, 2, 3],
          'enablePageAnimation': true,
          'nested': <String, Object?>{'a': 1},
          'searchSources': null,
          'webdav': <String>['https://dav.example.com', 'user', 'pass'],
          'deviceId': 'dev-1',
          'syncAuthEnabled': true,
          'uiFontScale': 1.25,
          'searchHistory': <String>['keyword'],
        });

        final records = await harness.adapter.readLocalRecords();
        final byKey = <String, AdapterRecord>{
          for (final record in records) record.key.parts.single: record,
        };

        expect(
          byKey.keys,
          unorderedEquals(<String>[
            'theme_mode',
            'cacheSize',
            'explore_pages',
            'enablePageAnimation',
            'nested',
          ]),
        );
        for (final entry in byKey.entries) {
          final record = entry.value;
          expect(record.domain, SyncDomains.setting);
          expect(record.field, '');
          expect(record.kind, SyncOpKind.upsert);
          expect(record.data, <String, Object?>{
            'value': harness.values[entry.key],
          });
        }
      },
    );

    test('skips values that cannot be JSON encoded', () async {
      final harness = _Harness(<String, Object?>{
        'theme_mode': 'dark',
        'notJson': Object(),
        'notFinite': double.nan,
      });

      final records = await harness.adapter.readLocalRecords();

      expect(records, hasLength(1));
      expect(records.single.key.parts, <String>['theme_mode']);
    });

    test('empty settings produce no records', () async {
      final harness = _Harness();

      expect(await harness.adapter.readLocalRecords(), isEmpty);
    });
  });

  group('applyRemote', () {
    test(
      'sets present records, keeps absent local keys, persists and reloads',
      () async {
        final harness = _Harness(<String, Object?>{
          'theme_mode': 'light',
          'cacheSize': 1024,
          'localOnly': 'keep',
          'syncAuthEnabled': false,
        });
        await emitSetting('theme_mode', 'dark');
        await emitSetting('cacheSize', 4096);

        await harness.adapter.applyRemote(store);

        expect(harness.values['theme_mode'], 'dark');
        expect(harness.values['cacheSize'], 4096);
        // Forward compatibility: local keys absent from the store are not
        // deleted.
        expect(harness.values['localOnly'], 'keep');
        // Device-local keys are never written from remote state.
        expect(harness.values['syncAuthEnabled'], false);
        expect(harness.persistCalls, 1);
        expect(harness.reloadCalls, 1);
        expect(harness.warnings, isEmpty);
      },
    );

    test('no visible records means no persist/reload (no-op)', () async {
      final harness = _Harness(<String, Object?>{'theme_mode': 'dark'});

      await harness.adapter.applyRemote(store);

      expect(harness.values, <String, Object?>{'theme_mode': 'dark'});
      expect(harness.persistCalls, 0);
      expect(harness.reloadCalls, 0);
    });

    test('ignores device-local and tombstoned records with warnings', () async {
      final harness = _Harness(<String, Object?>{
        'syncAuthEnabled': false,
        'webdav': <String>[],
      });
      await emitSetting('syncAuthEnabled', true);
      await emitSetting('webdav', <String>['https://evil.example.com']);
      await tombstoneSetting(<String>['removedSetting']);

      await harness.adapter.applyRemote(store);

      expect(harness.values['syncAuthEnabled'], false);
      expect(harness.values['webdav'], <String>[]);
      expect(harness.values.containsKey('removedSetting'), isFalse);
      expect(harness.persistCalls, 0);
      expect(harness.reloadCalls, 0);
      expect(harness.warnings, hasLength(2));
    });

    test('ignores malformed records and applies the valid ones', () async {
      final harness = _Harness(<String, Object?>{'theme_mode': 'light'});
      // Wrong number of key segments.
      await emitSetting('', 'x', parts: <String>['a', 'b']);
      // Unexpected field group.
      await emitSetting('x', 'remote', field: 'meta');
      // Missing value.
      await emitSetting('missing', null, data: <String, Object?>{'other': 1});
      // Null value must not clear the local setting.
      await emitSetting(
        'nullValue',
        null,
        data: <String, Object?>{'value': null},
      );
      // A valid record must still be applied.
      await emitSetting('valid', 'remote');

      await harness.adapter.applyRemote(store);

      expect(harness.values, <String, Object?>{
        'theme_mode': 'light',
        'valid': 'remote',
      });
      expect(harness.persistCalls, 1);
      expect(harness.reloadCalls, 1);
      expect(harness.warnings, hasLength(4));
    });

    test('read -> store -> apply roundtrips JSON values', () async {
      final source = _Harness(<String, Object?>{
        'theme_mode': 'dark',
        'cacheSize': 2048,
        'scale': 1.25,
        'enable': true,
        'pages': <int>[1, 2],
        'nested': <String, Object?>{
          'a': <Object?>[true, null, 'x'],
        },
        'empty': '',
        'webdav': <String>['https://dav.example.com'],
      });
      for (final record in await source.adapter.readLocalRecords()) {
        await store.emit(
          domain: record.domain,
          key: record.key,
          field: record.field,
          kind: record.kind,
          data: record.data,
        );
      }

      final target = _Harness();
      await target.adapter.applyRemote(store);

      expect(target.values, <String, Object?>{
        'theme_mode': 'dark',
        'cacheSize': 2048,
        'scale': 1.25,
        'enable': true,
        'pages': <int>[1, 2],
        'nested': <String, Object?>{
          'a': <Object?>[true, null, 'x'],
        },
        'empty': '',
      });
      expect(target.values.containsKey('webdav'), isFalse);
      expect(target.warnings, isEmpty);
    });
  });
}
