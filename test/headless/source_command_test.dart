import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/contract.dart';
import 'package:venera/headless/execution_context.dart';
import 'package:venera/headless/source_service.dart';

void main() {
  group('source command runner', () {
    test(
      'aggregate search preserves source order and reports partial result',
      () async {
        var first = _source(
          key: 'first',
          search: SearchPageData(null, (keyword, page, options) async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return Res([_comic('first', '1')], subData: 1);
          }, null),
        );
        var second = _source(
          key: 'second',
          search: SearchPageData(
            null,
            (keyword, page, options) async => const Res.error('offline'),
            null,
          ),
        );
        var runner = _runner([first, second]);
        var result = await runner.run(
          invocation: CliCommandRunner.parseInvocation(const [
            'comic',
            'search',
            'query',
            '--source',
            'first',
            '--source',
            'second',
            '--allow-partial',
          ]),
          transport: CliTransport.direct,
          guiAvailable: false,
        );

        expect(result.ok, isTrue);
        expect(result.meta['partial'], isTrue);
        var data = result.data as Map;
        expect(
          ((data['groups'] as List).single as Map)['source']['key'],
          'first',
        );
        expect(((data['failures'] as List).single as Map)['source'], 'second');
        expect(result.warnings.single.code, 'source_failed');
      },
    );

    test('partial aggregate is exit 7 unless explicitly allowed', () async {
      var good = _source(
        key: 'good',
        search: SearchPageData(
          null,
          (keyword, page, options) async => Res([_comic('good', '1')]),
          null,
        ),
      );
      var bad = _source(
        key: 'bad',
        search: SearchPageData(
          null,
          (keyword, page, options) async => const Res.error('failed'),
          null,
        ),
      );
      var result = await _runner([good, bad]).run(
        invocation: CliCommandRunner.parseInvocation(const [
          'comic',
          'search',
          'q',
          '-s',
          'good',
          '-s',
          'bad',
        ]),
        transport: CliTransport.direct,
        guiAvailable: false,
      );

      expect(result.ok, isFalse);
      expect(result.exitCode, 7);
      expect(result.error?.code, 'partial_failure');
      expect(result.data, isNotNull);
      expect(result.meta['partial'], isTrue);
    });

    test(
      'bounded --all fetches the requested number of one-based pages',
      () async {
        var pages = <int>[];
        var source = _source(
          key: 'paged',
          search: SearchPageData(null, (keyword, page, options) async {
            pages.add(page);
            return Res([_comic('paged', '$page')], subData: 5);
          }, null),
        );
        var result = await _runner([source]).run(
          invocation: CliCommandRunner.parseInvocation(const [
            'comic',
            'search',
            'q',
            '--source',
            'paged',
            '--all',
            '--max-pages',
            '2',
          ]),
          transport: CliTransport.direct,
          guiAvailable: false,
        );

        expect(result.ok, isTrue);
        expect(pages, [1, 2]);
        var group = ((result.data as Map)['groups'] as List).single as Map;
        expect((group['items'] as List).length, 2);
        expect((group['pagination'] as Map)['fetchedPages'], 2);
      },
    );

    test('cursor sources reject numeric pages', () async {
      var source = _source(
        key: 'cursor',
        search: SearchPageData(
          null,
          null,
          (keyword, cursor, options) async => const Res([], subData: null),
        ),
      );
      var result = await _runner([source]).run(
        invocation: CliCommandRunner.parseInvocation(const [
          'comic',
          'search',
          'q',
          '--source',
          'cursor',
          '--page',
          '2',
        ]),
        transport: CliTransport.direct,
        guiAvailable: false,
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'invalid_arguments');
      expect(result.exitCode, 2);
    });

    test('multi-select search options accept JSON arrays', () {
      var source = _source(
        key: 'options',
        search: SearchPageData(
          [
            SearchOptions(
              LinkedHashMap.of(const {'a': 'A', 'b': 'B'}),
              'Tags',
              'multi-select',
              '[]',
            ),
          ],
          (keyword, page, options) async => const Res([]),
          null,
        ),
      );
      var service = _service([source]);

      expect(
        service.resolveSearchOptions(
          source,
          fullOptions: const [
            ['a', 'b'],
          ],
        ),
        ['["a","b"]'],
      );
      expect(
        () => service.resolveSearchOptions(
          source,
          fullOptions: const [
            ['missing'],
          ],
        ),
        throwsA(isA<CliFailure>()),
      );
    });

    test('page limit reports more data when it truncates a page', () async {
      var source = _source(
        key: 'limited',
        search: SearchPageData(
          null,
          (keyword, page, options) async =>
              Res([_comic('limited', '1'), _comic('limited', '2')], subData: 1),
          null,
        ),
      );
      var result = await _runner([source]).run(
        invocation: CliCommandRunner.parseInvocation(const [
          'comic',
          'search',
          'q',
          '--source',
          'limited',
          '--limit',
          '1',
        ]),
        transport: CliTransport.direct,
        guiAvailable: false,
      );

      expect(result.ok, isTrue);
      var group = ((result.data as Map)['groups'] as List).single as Map;
      expect((group['items'] as List).length, 1);
      expect((group['pagination'] as Map)['hasMore'], isTrue);
    });

    test(
      'mixed explore adapts one-based CLI page to zero-based source index',
      () async {
        int? receivedIndex;
        var source = _source(
          key: 'mixed',
          explore: [
            ExplorePageData('Mixed', ExplorePageType.mixed, null, null, null, (
              index,
            ) async {
              receivedIndex = index;
              return Res(<Object>[
                <Comic>[_comic('mixed', '1')],
              ], subData: 3);
            }),
          ],
        );
        var service = _service([source]);
        var result = await service.showExplorePage(
          sourceKey: 'mixed',
          title: 'Mixed',
          pagination: const CliPaginationRequest(page: 2),
        );

        expect(receivedIndex, 1);
        expect(result['index'], 1);
        expect((result['pagination'] as Map)['page'], 2);
      },
    );

    test('source inventory includes parse failures', () {
      var ready = _source(key: 'ready');
      var service = CliSourceService(
        findSource: (key) => key == ready.key ? ready : null,
        allSources: () => [ready],
        sourceInstallations: () => [
          ComicSourceInstallation.ready(ready),
          ComicSourceInstallation.failed('/tmp/broken.js', 'syntax error'),
        ],
      );

      var result = service.listSources();
      expect(result.map((item) => item['state']), ['ready', 'parse_error']);
      expect(result.last['key'], 'broken');
      expect(result.last['error'], 'syntax error');
    });
  });
}

CliCommandRunner _runner(List<ComicSource> sources) {
  return CliCommandRunner(sources: _service(sources));
}

CliSourceService _service(List<ComicSource> sources) {
  var byKey = {for (var source in sources) source.key: source};
  return CliSourceService(
    findSource: (key) => byKey[key],
    allSources: () => sources,
    sourceInstallations: () =>
        sources.map(ComicSourceInstallation.ready).toList(),
  );
}

Comic _comic(String source, String id) {
  return Comic(
    'Comic $id',
    'https://example.test/$id.jpg',
    id,
    null,
    const [],
    '',
    source,
    null,
    null,
  );
}

ComicSource _source({
  required String key,
  SearchPageData? search,
  FavoriteData? favorite,
  List<ExplorePageData> explore = const [],
  LoadComicFunc? loadInfo,
  CategoryData? category,
  CategoryComicsData? categoryComics,
}) {
  return ComicSource(
    key,
    key,
    null,
    category,
    categoryComics,
    favorite,
    explore,
    search,
    null,
    loadInfo,
    null,
    null,
    null,
    null,
    '/tmp/$key.js',
    'https://example.test/$key.js',
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
