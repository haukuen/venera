import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/app/adapters/comic_setting_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/sqlite_store.dart';

const _deviceId = 'aaaaaaaa-1111-2222-3333-444444444444';

/// A `comicSpecificSettings` map plus the callbacks the adapter needs,
/// mirroring how the app wires `appdata.settings['comicSpecificSettings']`.
class _Harness {
  _Harness([Map<String, Object?>? initial]) {
    if (initial != null) settings.addAll(initial);
  }

  final Map<String, Object?> settings = <String, Object?>{};
  final List<String> warnings = <String>[];
  int setCalls = 0;
  int persistCalls = 0;
  int reloadCalls = 0;

  late final ComicSettingAdapter adapter = ComicSettingAdapter(
    readComicSettings: () => settings,
    set: (comicKey, value) {
      settings[comicKey] = value;
      setCalls++;
    },
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
    dir = Directory.systemTemp.createTempSync('venera-comic-setting-');
    store = await SqliteSyncStore.open(
      dbPath: '${dir.path}/sync.db',
      deviceId: _deviceId,
    );
  });

  tearDown(() async {
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> emitRaw(
    List<String> parts, {
    String field = '',
    Map<String, Object?>? data,
    bool deleted = false,
  }) async {
    final key = SyncKey(parts);
    await store.emit(
      domain: SyncDomains.comicSetting,
      key: key,
      field: field,
      kind: SyncOpKind.upsert,
      data: data,
    );
    if (deleted) {
      await store.emit(
        domain: SyncDomains.comicSetting,
        key: key,
        field: field,
        kind: SyncOpKind.del,
      );
    }
  }

  Future<void> emitComicSetting(
    String comicKey,
    Object? value, {
    bool deleted = false,
  }) => emitRaw(
    <String>[comicKey, ''],
    data: <String, Object?>{'settings': value},
    deleted: deleted,
  );

  group('readLocalRecords', () {
    test('projects one register per comic key', () async {
      final harness = _Harness(<String, Object?>{
        '123@sourceA': <String, Object?>{
          'enabled': true,
          'readerMode': 'gallery',
        },
        '456@sourceB': <String, Object?>{},
      });

      final records = await harness.adapter.readLocalRecords();

      expect(records, hasLength(2));
      for (final record in records) {
        expect(record.domain, SyncDomains.comicSetting);
        expect(record.field, '');
        expect(record.kind, SyncOpKind.upsert);
        expect(record.key.parts, hasLength(2));
        expect(record.key.parts[1], '');
      }
      final byComic = <String, AdapterRecord>{
        for (final record in records) record.key.parts[0]: record,
      };
      expect(
        byComic.keys,
        unorderedEquals(<String>['123@sourceA', '456@sourceB']),
      );
      expect(byComic['123@sourceA']!.data, <String, Object?>{
        'settings': <String, Object?>{'enabled': true, 'readerMode': 'gallery'},
      });
      expect(byComic['456@sourceB']!.data, <String, Object?>{
        'settings': <String, Object?>{},
      });
    });

    test('skips empty keys, non-map and non-encodable values', () async {
      final harness = _Harness(<String, Object?>{
        'good@src': <String, Object?>{'a': 1},
        '': <String, Object?>{'b': 2},
        'notMap@src': 'plain text',
        'object@src': <String, Object?>{'x': Object()},
      });

      final records = await harness.adapter.readLocalRecords();

      expect(records, hasLength(1));
      expect(records.single.key.parts, <String>['good@src', '']);
      expect(harness.warnings, hasLength(3));
    });

    test('empty map produces no records', () async {
      expect(await _Harness().adapter.readLocalRecords(), isEmpty);
    });
  });

  group('applyRemote', () {
    test(
      'sets present records, keeps absent local entries, persists once',
      () async {
        final harness = _Harness(<String, Object?>{
          'keep@src': <String, Object?>{'a': 1},
          'update@src': <String, Object?>{'old': true},
          'localOnly@src': <String, Object?>{'z': 9},
        });
        await emitComicSetting('update@src', <String, Object?>{'new': true});
        await emitComicSetting('add@src', <String, Object?>{'enabled': false});

        await harness.adapter.applyRemote(store);

        expect(harness.settings['update@src'], <String, Object?>{'new': true});
        expect(harness.settings['add@src'], <String, Object?>{
          'enabled': false,
        });
        // Forward compatibility: absent local entries are not deleted.
        expect(harness.settings['keep@src'], <String, Object?>{'a': 1});
        expect(harness.settings['localOnly@src'], <String, Object?>{'z': 9});
        expect(harness.setCalls, 2);
        expect(harness.persistCalls, 1);
        expect(harness.reloadCalls, 1);
        expect(harness.warnings, isEmpty);
      },
    );

    test('no visible records means no persist/reload (no-op)', () async {
      final harness = _Harness(<String, Object?>{
        'keep@src': <String, Object?>{'a': 1},
      });

      await harness.adapter.applyRemote(store);

      expect(harness.settings, <String, Object?>{
        'keep@src': <String, Object?>{'a': 1},
      });
      expect(harness.persistCalls, 0);
      expect(harness.reloadCalls, 0);
    });

    test('identical remote value is a no-op', () async {
      final harness = _Harness(<String, Object?>{
        'same@src': <String, Object?>{
          'a': 1,
          'b': <int>[1, 2],
        },
      });
      await emitComicSetting('same@src', <String, Object?>{
        'a': 1,
        'b': <int>[1, 2],
      });

      await harness.adapter.applyRemote(store);

      expect(harness.setCalls, 0);
      expect(harness.persistCalls, 0);
      expect(harness.reloadCalls, 0);
      expect(harness.warnings, isEmpty);
    });

    test(
      'tolerates malformed records, applies valid ones, accepts flat key',
      () async {
        final harness = _Harness();
        // Malformed shapes: 3 segments, reserved segment set, empty comic key,
        // payload without settings, non-map settings.
        await emitRaw(
          <String>['a', 'b', 'c'],
          data: <String, Object?>{
            'settings': <String, Object?>{'x': 1},
          },
        );
        await emitRaw(
          <String>['x@src', 'readerMode'],
          data: <String, Object?>{
            'settings': <String, Object?>{'x': 1},
          },
        );
        await emitRaw(
          <String>[''],
          data: <String, Object?>{
            'settings': <String, Object?>{'x': 1},
          },
        );
        await emitRaw(
          <String>['noSettings@src', ''],
          data: <String, Object?>{'other': 1},
        );
        await emitRaw(
          <String>['badSettings@src', ''],
          data: <String, Object?>{'settings': 'not a map'},
        );
        // A visible tombstone must not resurrect the settings.
        await emitComicSetting('gone@src', <String, Object?>{
          'a': 1,
        }, deleted: true);
        // Forward-compatible single-segment key form.
        await emitRaw(
          <String>['flat@src'],
          data: <String, Object?>{
            'settings': <String, Object?>{'flat': true},
          },
        );

        await harness.adapter.applyRemote(store);

        expect(harness.settings, <String, Object?>{
          'flat@src': <String, Object?>{'flat': true},
        });
        expect(harness.persistCalls, 1);
        expect(harness.reloadCalls, 1);
        expect(harness.warnings, hasLength(5));
      },
    );

    test('read -> store -> apply roundtrips comic settings', () async {
      final source = _Harness(<String, Object?>{
        '123@sourceA': <String, Object?>{
          'enabled': true,
          'readerMode': 'gallery',
          'scale': 1.25,
          'pages': <int>[1, 2],
        },
        '456@sourceB': <String, Object?>{},
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

      expect(target.settings, <String, Object?>{
        '123@sourceA': <String, Object?>{
          'enabled': true,
          'readerMode': 'gallery',
          'scale': 1.25,
          'pages': <int>[1, 2],
        },
        '456@sourceB': <String, Object?>{},
      });
      expect(target.warnings, isEmpty);
    });

    test('reload() invokes the injected callback', () async {
      final harness = _Harness();

      await harness.adapter.reload();

      expect(harness.reloadCalls, 1);
    });
  });
}
