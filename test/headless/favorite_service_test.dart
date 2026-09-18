import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/execution_context.dart';
import 'package:venera/headless/source_service.dart';

void main() {
  group('remote favorite safety', () {
    test(
      'never retries a write and trusts a separately verified final state',
      () async {
        var favorited = false;
        var writes = 0;
        var retryingEntryPointCalls = 0;
        String? receivedFavoriteId;
        var favorite = FavoriteData(
          key: 'single',
          title: 'Single',
          multiFolder: false,
          loadComic: null,
          loadNext: null,
          addOrDelFavorite: (comicId, folderId, adding, favoriteId) async {
            retryingEntryPointCalls++;
            return const Res.error('must not call retrying entry point');
          },
          addOrDelFavoriteOnce: (comicId, folderId, adding, favoriteId) async {
            writes++;
            receivedFavoriteId = favoriteId;
            favorited = adding;
            return const Res.error('response was lost');
          },
        );
        var source = _source(
          key: 'single',
          favorite: favorite,
          loadInfo: (id) async => Res(_details('single', id, favorited)),
        );

        var result = await _runner(source).run(
          invocation: CliCommandRunner.parseInvocation(const [
            'favorite',
            'remote',
            'add',
            '--source',
            'single',
            '--id',
            'comic',
            '--favorite-id',
            'opaque-favorite-id',
          ]),
          transport: CliTransport.direct,
          guiAvailable: false,
        );

        expect(result.ok, isTrue);
        expect(writes, 1);
        expect(retryingEntryPointCalls, 0);
        expect(receivedFavoriteId, 'opaque-favorite-id');
        expect(
          result.warnings.map((warning) => warning.code),
          contains('write_response_error_but_verified'),
        );
      },
    );

    test(
      'refuses a potentially toggling write when state is unknown',
      () async {
        var writes = 0;
        var source = _source(
          key: 'unknown',
          favorite: FavoriteData(
            key: 'unknown',
            title: 'Unknown',
            multiFolder: false,
            loadComic: null,
            loadNext: null,
            addOrDelFavorite: (comicId, folderId, adding, favoriteId) async {
              writes++;
              return const Res(true);
            },
          ),
          loadInfo: (id) async => Res(_details('unknown', id, null)),
        );

        var result = await _runner(source).run(
          invocation: CliCommandRunner.parseInvocation(const [
            'favorite',
            'remote',
            'add',
            '--source',
            'unknown',
            '--id',
            'comic',
          ]),
          transport: CliTransport.direct,
          guiAvailable: false,
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'state_unknown');
        expect(result.exitCode, 6);
        expect(writes, 0);
      },
    );

    test(
      'folder scan prevents an implicit move for single-folder sources',
      () async {
        var writes = 0;
        var favorite = FavoriteData(
          key: 'multi',
          title: 'Multi',
          multiFolder: true,
          singleFolderForSingleComic: true,
          loadFolders: ([comicId]) async =>
              const Res({'target': 'Target', 'other': 'Other'}),
          loadComic: (page, [folder]) async => const Res([], subData: 1),
          loadNext: null,
          addOrDelFavorite: (comicId, folderId, adding, favoriteId) async {
            writes++;
            return const Res(true);
          },
        );
        var source = _source(
          key: 'multi',
          favorite: favorite,
          loadInfo: (id) async => Res(_details('multi', id, true)),
        );

        var result = await _runner(source).run(
          invocation: CliCommandRunner.parseInvocation(const [
            'favorite',
            'remote',
            'add',
            '--source',
            'multi',
            '--id',
            'comic',
            '--folder',
            'target',
          ]),
          transport: CliTransport.direct,
          guiAvailable: false,
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'state_unknown');
        expect(result.error?.message, contains('implicit move'));
        expect(writes, 0);
      },
    );

    test(
      'unknown membership is resolved by bounded preflight and verification scans',
      () async {
        var favorited = false;
        var inTarget = false;
        var scans = 0;
        var favorite = FavoriteData(
          key: 'multi',
          title: 'Multi',
          multiFolder: true,
          loadFolders: ([comicId]) async => const Res({'target': 'Target'}),
          loadComic: (page, [folder]) async {
            scans++;
            return Res(
              inTarget ? [_comic('multi', 'comic')] : const <Comic>[],
              subData: 1,
            );
          },
          loadNext: null,
          addOrDelFavorite: (comicId, folderId, adding, favoriteId) async {
            favorited = adding;
            inTarget = adding;
            return const Res(true);
          },
        );
        var source = _source(
          key: 'multi',
          favorite: favorite,
          loadInfo: (id) async => Res(_details('multi', id, favorited)),
        );

        var result = await _runner(source).run(
          invocation: CliCommandRunner.parseInvocation(const [
            'favorite',
            'remote',
            'add',
            '--source',
            'multi',
            '--id',
            'comic',
            '--folder',
            'target',
            '--verify-max-pages',
            '2',
          ]),
          transport: CliTransport.direct,
          guiAvailable: false,
        );

        expect(result.ok, isTrue);
        expect((result.data as Map)['verification'], 'verified');
        expect(scans, 2);
      },
    );

    test('folder delete dry-run reports required destructive flags', () async {
      var deletes = 0;
      var favorite = FavoriteData(
        key: 'folders',
        title: 'Folders',
        multiFolder: true,
        loadFolders: ([comicId]) async => const Res({'folder': 'Folder'}),
        loadComic: (page, [folder]) async =>
            Res([_comic('folders', 'comic')], subData: 1),
        loadNext: null,
        deleteFolder: (folder) async {
          deletes++;
          return const Res(true);
        },
      );
      var result = await _runner(_source(key: 'folders', favorite: favorite))
          .run(
            invocation: CliCommandRunner.parseInvocation(const [
              'favorite',
              'remote',
              'folder',
              'delete',
              '--source',
              'folders',
              '--folder',
              'folder',
              '--dry-run',
            ]),
            transport: CliTransport.direct,
            guiAvailable: false,
          );

      expect(result.ok, isTrue);
      var data = result.data as Map;
      expect(data['allowed'], isFalse);
      expect(data['requiredFlags'], ['--yes', '--force-non-empty']);
      expect(deletes, 0);
    });

    test(
      'folder list exposes a declared aggregate folder when omitted',
      () async {
        var favorite = FavoriteData(
          key: 'folders',
          title: 'Folders',
          multiFolder: true,
          allFavoritesId: 'all',
          loadFolders: ([comicId]) async => const Res({'target': 'Target'}),
          loadComic: (page, [folder]) async => const Res([]),
          loadNext: null,
        );
        var result = await _runner(_source(key: 'folders', favorite: favorite))
            .run(
              invocation: CliCommandRunner.parseInvocation(const [
                'favorite',
                'remote',
                'folder',
                'list',
                '--source',
                'folders',
              ]),
              transport: CliTransport.direct,
              guiAvailable: false,
            );

        expect(result.ok, isTrue);
        var folders = result.data as List;
        expect(folders.first, {
          'id': 'all',
          'name': 'All',
          'isAllFavorites': true,
          'synthetic': true,
        });
      },
    );

    test('aggregate all-favorites folder is never a mutation target', () async {
      var writes = 0;
      var favorite = FavoriteData(
        key: 'folders',
        title: 'Folders',
        multiFolder: true,
        allFavoritesId: 'all',
        loadFolders: ([comicId]) async => const Res({'target': 'Target'}),
        loadComic: (page, [folder]) async => const Res([]),
        loadNext: null,
        addOrDelFavorite: (comicId, folderId, adding, favoriteId) async {
          writes++;
          return const Res(true);
        },
      );
      var result = await _runner(_source(key: 'folders', favorite: favorite))
          .run(
            invocation: CliCommandRunner.parseInvocation(const [
              'favorite',
              'remote',
              'add',
              '--source',
              'folders',
              '--id',
              'comic',
              '--folder',
              'all',
            ]),
            transport: CliTransport.direct,
            guiAvailable: false,
          );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'protected_folder');
      expect(result.exitCode, 6);
      expect(writes, 0);
    });

    test('aggregate all-favorites folder is never deletable', () async {
      var favorite = FavoriteData(
        key: 'folders',
        title: 'Folders',
        multiFolder: true,
        allFavoritesId: 'all',
        loadFolders: ([comicId]) async => const Res({'all': 'All'}),
        loadComic: (page, [folder]) async => const Res([]),
        loadNext: null,
        deleteFolder: (folder) async => const Res(true),
      );
      var result = await _runner(_source(key: 'folders', favorite: favorite))
          .run(
            invocation: CliCommandRunner.parseInvocation(const [
              'favorite',
              'remote',
              'folder',
              'delete',
              '--source',
              'folders',
              '--folder',
              'all',
              '--yes',
              '--force-non-empty',
            ]),
            transport: CliTransport.direct,
            guiAvailable: false,
          );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'protected_folder');
      expect(result.exitCode, 6);
    });
  });
}

CliCommandRunner _runner(ComicSource source) {
  var service = CliSourceService(
    findSource: (key) => key == source.key ? source : null,
    allSources: () => [source],
    sourceInstallations: () => [ComicSourceInstallation.ready(source)],
  );
  return CliCommandRunner(sources: service);
}

Comic _comic(String source, String id) {
  return Comic(
    'Comic',
    'https://example.test/cover',
    id,
    null,
    const [],
    '',
    source,
    null,
    null,
  );
}

ComicDetails _details(String source, String id, bool? isFavorite) {
  return ComicDetails.fromJson({
    'title': 'Comic',
    'subtitle': null,
    'cover': 'https://example.test/cover',
    'description': null,
    'tags': <String, List<String>>{},
    'chapters': null,
    'sourceKey': source,
    'comicId': id,
    'isFavorite': isFavorite,
  });
}

ComicSource _source({
  required String key,
  FavoriteData? favorite,
  LoadComicFunc? loadInfo,
}) {
  return ComicSource(
    key,
    key,
    null,
    null,
    null,
    favorite,
    const [],
    null,
    null,
    loadInfo,
    null,
    null,
    null,
    null,
    '/tmp/$key.js',
    '',
    '1.0.0',
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
