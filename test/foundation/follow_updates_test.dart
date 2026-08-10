import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';

class _TestPathProviderPlatform extends PathProviderPlatform {
  _TestPathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

FavoriteItem _comic(String id, ComicType type) {
  return FavoriteItem(
    id: id,
    name: 'Comic $id',
    coverPath: 'cover-$id',
    author: 'Author $id',
    type: type,
    tags: const [],
  );
}

ComicSource _mockSource(String key, LoadComicFunc? loadComicInfo) {
  return ComicSource(
    'Mock $key',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    null,
    null,
    null,
    'mock',
    'mock',
    '1.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalFavoritesManager manager;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync(
      'venera-follow-updates-test-',
    );
    PathProviderPlatform.instance = _TestPathProviderPlatform(tempDir.path);
    App.dataPath = tempDir.path;

    appdata.settings['followUpdatesFolder'] = null;
    appdata.settings['skipCheckIfHasNewUpdate'] = false;
    appdata.settings['comicUpdateCheckInterval'] = '24';
    manager = LocalFavoritesManager();
    await appdata.init();
    await manager.init();
    await pumpEventQueue();
  });

  tearDown(() {
    if (manager.isInitialized) {
      manager.close();
    }
    LocalFavoritesManager.cache = null;
    ComicSourceManager().all().forEach((source) {
      if (source.key.startsWith('mock-')) {
        ComicSourceManager().remove(source.key);
      }
    });
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'skips comics already marked as updated when skipCheckIfHasNewUpdate is true',
    () async {
      const folder = 'Follow Updates';
      const key = 'mock-skip';
      var loadCalls = 0;
      ComicSourceManager().add(
        _mockSource(key, (id) async {
          loadCalls++;
          return Res(
            ComicDetails.fromJson({
              'title': 'Comic',
              'cover': 'cover',
              'sourceKey': key,
              'comicId': id,
              'tags': <String, dynamic>{},
            }),
          );
        }),
      );
      var type = ComicType.fromKey(key);

      manager.createFolder(folder);
      manager.prepareTableForFollowUpdates(folder);
      manager.addComic(folder, _comic('comic-1', type), null, 'chapter-1');
      manager.updateUpdateTime(folder, 'comic-1', type, 'chapter-2');
      expect(manager.countUpdates(folder), 1);

      appdata.settings['skipCheckIfHasNewUpdate'] = true;
      await updateFolder(folder, true).toList();
      expect(loadCalls, 0, reason: 'has_new_update comic should be skipped');

      appdata.settings['skipCheckIfHasNewUpdate'] = false;
      await updateFolder(folder, true).toList();
      expect(loadCalls, 1, reason: 'should re-check when skip is disabled');
    },
  );

  test('respects comicUpdateCheckInterval when deciding to re-check', () async {
    const folder = 'Follow Updates';
    const key = 'mock-interval';
    var loadCalls = 0;
    ComicSourceManager().add(
      _mockSource(key, (id) async {
        loadCalls++;
        return Res(
          ComicDetails.fromJson({
            'title': 'Comic',
            'cover': 'cover',
            'sourceKey': key,
            'comicId': id,
            'tags': <String, dynamic>{},
          }),
        );
      }),
    );
    var type = ComicType.fromKey(key);

    manager.createFolder(folder);
    manager.prepareTableForFollowUpdates(folder);
    manager.addComic(folder, _comic('comic-1', type), null, 'chapter-1');

    // Set last_check_time to 2 hours ago.
    final db = openSqliteDatabase('${App.dataPath}/local_favorite.db');
    db.execute(
      '''
      update "$folder"
      set last_check_time = ?
      where id == ? and type == ?;
    ''',
      [
        DateTime.now()
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
        'comic-1',
        type.value,
      ],
    );
    db.dispose();

    // Interval 24h: 2h ago is within the interval, so it should be skipped.
    appdata.settings['comicUpdateCheckInterval'] = '24';
    await updateFolder(folder, false).toList();
    expect(loadCalls, 0, reason: '2h ago is within 24h interval');

    // Interval 1h: 2h ago exceeds the interval, so it should be re-checked.
    appdata.settings['comicUpdateCheckInterval'] = '1';
    await updateFolder(folder, false).toList();
    expect(loadCalls, 1, reason: '2h ago exceeds 1h interval');
  });
}
