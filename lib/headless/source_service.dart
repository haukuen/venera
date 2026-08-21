import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

import 'contract.dart';
import 'execution_context.dart';

typedef CliFindSource = ComicSource? Function(String key);
typedef CliAllSources = List<ComicSource> Function();
typedef CliSourceInstallations = List<ComicSourceInstallation> Function();

ComicSource? _defaultFindSource(String key) => ComicSource.find(key);
List<ComicSource> _defaultAllSources() => ComicSource.all();
List<ComicSourceInstallation> _defaultInstallations() =>
    ComicSourceManager().installations();

class CliPaginationRequest {
  final int page;
  final String? cursor;
  final bool all;
  final int? maxPages;
  final int? limit;

  const CliPaginationRequest({
    this.page = 1,
    this.cursor,
    this.all = false,
    this.maxPages,
    this.limit,
  });

  void validate({required bool cursorMode}) {
    if (page < 1) throw CliFailure.invalid('--page must be at least 1.');
    if (maxPages != null && maxPages! < 1) {
      throw CliFailure.invalid('--max-pages must be at least 1.');
    }
    if (limit != null && limit! < 1) {
      throw CliFailure.invalid('--limit must be at least 1.');
    }
    if (!cursorMode && cursor != null) {
      throw CliFailure.invalid('--cursor cannot be used with a page source.');
    }
    if (cursorMode && page != 1) {
      throw CliFailure.invalid('--page cannot be used with a cursor source.');
    }
    if (all && maxPages == null && limit == null) {
      throw CliFailure.invalid('--all requires --max-pages or --limit.');
    }
  }
}

class CliSourceService {
  final CliFindSource findSource;
  final CliAllSources allSources;
  final CliSourceInstallations sourceInstallations;

  const CliSourceService({
    this.findSource = _defaultFindSource,
    this.allSources = _defaultAllSources,
    this.sourceInstallations = _defaultInstallations,
  });

  List<Map<String, dynamic>> listSources() {
    var records = sourceInstallations();
    return records.map(_installationToJson).toList();
  }

  Map<String, dynamic> showSource(String key) {
    var record = sourceInstallations().firstWhere(
      (item) =>
          item.source?.key == key ||
          _fileNameWithoutExtension(item.filePath) == key,
      orElse: () => throw CliFailure.notFound(
        'Comic source "$key" was not found.',
        source: key,
        operation: 'source.show',
      ),
    );
    return _installationToJson(record, detailed: true);
  }

  ComicSource requireSource(String key, {String operation = 'source'}) {
    var source = findSource(key);
    if (source == null) {
      throw CliFailure.notFound(
        'Comic source "$key" was not found or is not ready.',
        source: key,
        operation: operation,
      );
    }
    return source;
  }

  List<ComicSource> resolveSearchSources({
    required List<String> requested,
    required bool allSources,
  }) {
    List<String> keys;
    if (allSources) {
      keys = this
          .allSources()
          .where((source) => source.searchPageData != null)
          .map((source) => source.key)
          .toList();
    } else if (requested.isNotEmpty) {
      keys = requested;
    } else {
      keys = List<String>.from(appdata.settings['searchSources'] ?? const []);
    }
    var seen = <String>{};
    var sources = <ComicSource>[];
    for (var key in keys) {
      if (!seen.add(key)) continue;
      var source = requireSource(key, operation: 'comic.search');
      if (source.searchPageData == null) {
        throw CliFailure.unsupported(
          'Comic source "$key" does not support search.',
          source: key,
          operation: 'comic.search',
        );
      }
      sources.add(source);
    }
    if (sources.isEmpty) {
      throw CliFailure.notFound(
        'No search-capable comic sources are configured.',
        operation: 'comic.search',
      );
    }
    return sources;
  }

  List<String> resolveSearchOptions(
    ComicSource source, {
    List<dynamic>? fullOptions,
    Map<int, String> overrides = const {},
  }) {
    var schemas = source.searchPageData?.searchOptions ?? const [];
    var values = fullOptions == null
        ? schemas.map((schema) => schema.defaultValue).toList()
        : [
            for (var index = 0; index < fullOptions.length; index++)
              index < schemas.length
                  ? _encodeSearchOption(schemas[index], fullOptions[index])
                  : fullOptions[index].toString(),
          ];
    if (values.length != schemas.length) {
      throw CliFailure.invalid(
        'Expected ${schemas.length} search options for ${source.key}, got ${values.length}.',
      );
    }
    for (var entry in overrides.entries) {
      if (entry.key < 0 || entry.key >= schemas.length) {
        throw CliFailure.invalid(
          'Search option index ${entry.key} is out of range for ${source.key}.',
        );
      }
      values[entry.key] = entry.value;
    }
    for (var index = 0; index < schemas.length; index++) {
      var schema = schemas[index];
      if ((schema.type == 'select' || schema.type == 'dropdown') &&
          schema.options.isNotEmpty &&
          !schema.options.containsKey(values[index])) {
        throw CliFailure.invalid(
          'Invalid value "${values[index]}" for search option $index on ${source.key}.',
          details: {'allowed': schema.options.keys.toList()},
        );
      }
      if (schema.type == 'multi-select') {
        dynamic selected;
        try {
          selected = jsonDecode(values[index]);
        } on FormatException {
          throw CliFailure.invalid(
            'Search option $index on ${source.key} must be a JSON array.',
          );
        }
        if (selected is! List ||
            selected.any(
              (value) =>
                  value is! String ||
                  schema.options.isNotEmpty &&
                      !schema.options.containsKey(value),
            )) {
          throw CliFailure.invalid(
            'Invalid multi-select value for search option $index on ${source.key}.',
            details: {'allowed': schema.options.keys.toList()},
          );
        }
      }
    }
    return values;
  }

  Future<Map<String, dynamic>> search({
    required ComicSource source,
    required String keyword,
    required List<String> options,
    required CliPaginationRequest pagination,
  }) async {
    var data = source.searchPageData!;
    var list = await loadComicList(
      source: source,
      operation: 'comic.search',
      loadPage: data.loadPage == null
          ? null
          : (page) => data.loadPage!(keyword, page, options),
      loadNext: data.loadNext == null
          ? null
          : (cursor) => data.loadNext!(keyword, cursor, options),
      request: pagination,
    );
    return {
      'source': _sourceIdentity(source),
      'query': keyword,
      'effectiveOptions': options,
      ...list,
    };
  }

  Future<Map<String, dynamic>> showComic(
    String sourceKey,
    String comicId,
  ) async {
    var source = requireSource(sourceKey, operation: 'comic.show');
    var loader = source.loadComicInfo;
    if (loader == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide comic details.',
        source: sourceKey,
        operation: 'comic.show',
      );
    }
    var details = await _unwrap(
      await loader(comicId),
      source: sourceKey,
      operation: 'comic.show',
    );
    return comicDetailsToJson(details);
  }

  Future<List<Map<String, dynamic>>> comicChapters(
    String sourceKey,
    String comicId,
  ) async {
    var details = await _loadDetails(sourceKey, comicId, 'comic.chapters');
    return chaptersToJson(details.chapters);
  }

  Future<List<Map<String, dynamic>>> comicTags(
    String sourceKey,
    String comicId,
  ) async {
    var details = await _loadDetails(sourceKey, comicId, 'comic.tags');
    return [
      for (var entry in details.tags.entries)
        for (var value in entry.value) {'namespace': entry.key, 'value': value},
    ];
  }

  Future<List<Map<String, dynamic>>> listCategories(String sourceKey) async {
    var source = requireSource(sourceKey, operation: 'category.list');
    var data = source.categoryData;
    if (data == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide categories.',
        source: sourceKey,
        operation: 'category.list',
      );
    }
    try {
      var result = <Map<String, dynamic>>[];
      for (var part in data.categories) {
        List<CategoryItem> items;
        if (part is RandomCategoryPart) {
          // The GUI intentionally samples random entries. Discovery commands
          // must expose the complete stable set instead.
          items = part.all;
        } else if (part is DynamicCategoryPart) {
          dynamic raw = part.loader([]);
          if (raw is Future) raw = await raw;
          if (raw is! List) {
            throw const FormatException(
              'Dynamic category loader must return a list.',
            );
          }
          items = [
            for (var value in raw)
              if (value is Map && value['label'] is String)
                CategoryItem(
                  value['label'] as String,
                  PageJumpTarget.parse(source.key, value['target']),
                )
              else
                throw const FormatException(
                  'Dynamic category entries must contain a string label and target.',
                ),
          ];
        } else {
          items = part.categories;
        }
        result.add({
          'title': part.title,
          'kind': switch (part) {
            FixedCategoryPart() => 'fixed',
            RandomCategoryPart() => 'random',
            DynamicCategoryPart() => 'dynamic',
            _ => 'unknown',
          },
          'items': [
            for (var item in items)
              {
                'label': item.label,
                'target': pageJumpTargetToJson(item.target),
              },
          ],
        });
      }
      return result;
    } catch (error) {
      throw CliFailure.source(
        error.toString(),
        source: sourceKey,
        operation: 'category.list',
      );
    }
  }

  Future<List<Map<String, dynamic>>> categoryOptions({
    required String sourceKey,
    required String category,
    String? param,
  }) async {
    var options = await _resolveCategoryOptionSchemas(
      sourceKey: sourceKey,
      category: category,
      param: param,
    );
    return [
      for (var option in options)
        {
          'label': option.label,
          'values': [
            for (var entry in option.options.entries)
              {'value': entry.key, 'label': entry.value},
          ],
          'default': option.options.keys.firstOrNull,
        },
    ];
  }

  Future<Map<String, dynamic>> categoryComics({
    required String sourceKey,
    required String category,
    String? param,
    List<dynamic>? fullOptions,
    Map<int, String> overrides = const {},
    required CliPaginationRequest pagination,
  }) async {
    var source = requireSource(sourceKey, operation: 'category.comics');
    var data = source.categoryComicsData;
    if (data == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide category comics.',
        source: sourceKey,
        operation: 'category.comics',
      );
    }
    if (pagination.cursor != null) {
      throw CliFailure.invalid('Category comics use page pagination.');
    }
    var schemas = await _resolveCategoryOptionSchemas(
      sourceKey: sourceKey,
      category: category,
      param: param,
    );
    var options = fullOptions == null
        ? schemas
              .map((option) => option.options.keys.firstOrNull ?? '')
              .toList()
        : fullOptions.map((value) => value.toString()).toList();
    if (options.length != schemas.length) {
      throw CliFailure.invalid(
        'Expected ${schemas.length} category options, got ${options.length}.',
      );
    }
    for (var entry in overrides.entries) {
      if (entry.key < 0 || entry.key >= schemas.length) {
        throw CliFailure.invalid(
          'Category option index ${entry.key} is out of range.',
        );
      }
      options[entry.key] = entry.value;
    }
    for (var index = 0; index < schemas.length; index++) {
      if (!schemas[index].options.containsKey(options[index])) {
        throw CliFailure.invalid(
          'Invalid value "${options[index]}" for category option $index.',
          details: {'allowed': schemas[index].options.keys.toList()},
        );
      }
    }
    var list = await loadComicList(
      source: source,
      operation: 'category.comics',
      loadPage: (page) => data.load(category, param, options, page),
      request: pagination,
    );
    return {
      'source': _sourceIdentity(source),
      'category': category,
      'param': param,
      'effectiveOptions': options,
      ...list,
    };
  }

  List<Map<String, dynamic>> rankingOptions(String sourceKey) {
    var source = requireSource(sourceKey, operation: 'ranking.list');
    var ranking = source.categoryComicsData?.rankingData;
    if (ranking == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide rankings.',
        source: sourceKey,
        operation: 'ranking.list',
      );
    }
    return [
      for (var entry in ranking.options.entries)
        {'value': entry.key, 'label': entry.value},
    ];
  }

  Future<Map<String, dynamic>> rankingComics({
    required String sourceKey,
    String? rankingOption,
    required CliPaginationRequest pagination,
  }) async {
    var source = requireSource(sourceKey, operation: 'ranking.comics');
    var ranking = source.categoryComicsData?.rankingData;
    if (ranking == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide rankings.',
        source: sourceKey,
        operation: 'ranking.comics',
      );
    }
    var option = rankingOption ?? ranking.options.keys.firstOrNull;
    if (option == null || !ranking.options.containsKey(option)) {
      throw CliFailure.invalid(
        'Invalid ranking option "$option".',
        details: {'allowed': ranking.options.keys.toList()},
      );
    }
    var list = await loadComicList(
      source: source,
      operation: 'ranking.comics',
      loadPage: ranking.load == null
          ? null
          : (page) => ranking.load!(option, page),
      loadNext: ranking.loadWithNext == null
          ? null
          : (cursor) => ranking.loadWithNext!(option, cursor),
      request: pagination,
    );
    return {
      'source': _sourceIdentity(source),
      'ranking': {'value': option, 'label': ranking.options[option]},
      ...list,
    };
  }

  List<Map<String, dynamic>> listExplorePages(String sourceKey) {
    var source = requireSource(sourceKey, operation: 'explore.list');
    return [
      for (var index = 0; index < source.explorePages.length; index++)
        {
          'index': index + 1,
          'title': source.explorePages[index].title,
          'type': source.explorePages[index].type.name,
          'headless':
              source.explorePages[index].type != ExplorePageType.override,
        },
    ];
  }

  Future<Map<String, dynamic>> showExplorePage({
    required String sourceKey,
    int? index,
    String? title,
    required CliPaginationRequest pagination,
  }) async {
    var source = requireSource(sourceKey, operation: 'explore.show');
    if ((index == null) == (title == null)) {
      throw CliFailure.invalid(
        'Exactly one of --index or --title is required.',
      );
    }
    ExplorePageData data;
    var selectedIndex = index;
    if (index != null) {
      if (index < 1 || index > source.explorePages.length) {
        throw CliFailure.notFound(
          'Explore index $index was not found.',
          source: sourceKey,
          operation: 'explore.show',
        );
      }
      data = source.explorePages[index - 1];
    } else {
      var matches = source.explorePages.indexed
          .where((entry) => entry.$2.title == title)
          .toList();
      if (matches.length != 1) {
        throw CliFailure.conflict(
          'ambiguous_explore_title',
          matches.isEmpty
              ? 'Explore page "$title" was not found.'
              : 'More than one explore page is named "$title".',
          source: sourceKey,
          operation: 'explore.show',
        );
      }
      selectedIndex = matches.single.$1 + 1;
      data = matches.single.$2;
    }
    if (data.type == ExplorePageType.override) {
      throw CliFailure.unsupported(
        'This explore page requires its custom GUI.',
        source: sourceKey,
        operation: 'explore.show',
      );
    }
    Object content;
    Map<String, dynamic>? pageInfo;
    if (data.loadMultiPart != null) {
      if (pagination.page != 1 ||
          pagination.cursor != null ||
          pagination.all ||
          pagination.maxPages != null ||
          pagination.limit != null) {
        throw CliFailure.invalid(
          'This explore page is not paginated and does not accept pagination options.',
        );
      }
      var parts = await _unwrap(
        await data.loadMultiPart!(),
        source: sourceKey,
        operation: 'explore.show',
      );
      content = {
        'type': 'sections',
        'parts': parts.map(explorePartToJson).toList(),
      };
    } else if (data.loadPage != null || data.loadNext != null) {
      var list = await loadComicList(
        source: source,
        operation: 'explore.show',
        loadPage: data.loadPage,
        loadNext: data.loadNext,
        request: pagination,
      );
      content = {'type': 'comic_list', 'items': list['items']};
      pageInfo = Map<String, dynamic>.from(list['pagination'] as Map);
    } else if (data.loadMixed != null) {
      if (pagination.cursor != null) {
        throw CliFailure.invalid('Mixed explore pages use numeric pages.');
      }
      pagination.validate(cursorMode: false);
      var current = pagination.page;
      var fetched = 0;
      var itemCount = 0;
      var reachedLimit = false;
      int? maxPage;
      var blocks = <Map<String, dynamic>>[];
      do {
        CliExecutionContext.current?.cancellation.throwIfCancelled();
        var raw = await data.loadMixed!(current - 1);
        var result = await _unwrap(
          raw,
          source: sourceKey,
          operation: 'explore.show',
        );
        maxPage = raw.subData is int ? raw.subData as int : maxPage;
        for (var item in result) {
          if (item is ExplorePagePart) {
            var comics = item.comics;
            if (pagination.limit != null) {
              comics = comics.take(pagination.limit! - itemCount).toList();
            }
            if (comics.isNotEmpty || pagination.limit == null) {
              blocks.add({
                'type': 'section',
                'title': item.title,
                'items': comics.map(comicToJson).toList(),
                'viewMore': item.viewMore == null
                    ? null
                    : pageJumpTargetToJson(item.viewMore!),
              });
            }
            itemCount += comics.length;
          } else if (item is List<Comic>) {
            var comics = item;
            if (pagination.limit != null) {
              comics = comics.take(pagination.limit! - itemCount).toList();
            }
            blocks.add({
              'type': 'comic_list',
              'items': comics.map(comicToJson).toList(),
            });
            itemCount += comics.length;
          }
          if (pagination.limit != null && itemCount >= pagination.limit!) {
            reachedLimit = true;
            break;
          }
        }
        fetched++;
        if (!pagination.all ||
            reachedLimit ||
            (pagination.maxPages != null && fetched >= pagination.maxPages!) ||
            (maxPage != null && current >= maxPage)) {
          break;
        }
        current++;
      } while (true);
      content = {'type': 'mixed', 'blocks': blocks};
      pageInfo = {
        'kind': 'page',
        'page': pagination.page,
        'maxPage': maxPage,
        'hasMore': reachedLimit || maxPage == null || current < maxPage,
        'fetchedPages': fetched,
      };
    } else {
      throw CliFailure.unsupported(
        'This explore page has no headless loader.',
        source: sourceKey,
        operation: 'explore.show',
      );
    }
    return {
      'source': _sourceIdentity(source),
      'index': selectedIndex,
      'title': data.title,
      'type': data.type.name,
      'content': content,
      'pagination': pageInfo,
    };
  }

  Future<ComicDetails> _loadDetails(
    String sourceKey,
    String comicId,
    String operation,
  ) async {
    var source = requireSource(sourceKey, operation: operation);
    if (source.loadComicInfo == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide comic details.',
        source: sourceKey,
        operation: operation,
      );
    }
    return _unwrap(
      await source.loadComicInfo!(comicId),
      source: sourceKey,
      operation: operation,
    );
  }

  Future<List<CategoryComicsOptions>> _resolveCategoryOptionSchemas({
    required String sourceKey,
    required String category,
    String? param,
  }) async {
    var source = requireSource(sourceKey, operation: 'category.options');
    var data = source.categoryComicsData;
    if (data == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide category comics.',
        source: sourceKey,
        operation: 'category.options',
      );
    }
    List<CategoryComicsOptions> options;
    if (data.optionsLoader != null) {
      options = await _unwrap(
        await data.optionsLoader!(category, param),
        source: sourceKey,
        operation: 'category.options',
      );
    } else {
      options = data.options ?? const [];
    }
    return options.where((option) {
      if (option.notShowWhen.contains(category)) return false;
      if (option.showWhen != null) return option.showWhen!.contains(category);
      return true;
    }).toList();
  }

  Future<Map<String, dynamic>> loadComicList({
    required ComicSource source,
    required String operation,
    Future<Res<List<Comic>>> Function(int page)? loadPage,
    Future<Res<List<Comic>>> Function(String? cursor)? loadNext,
    required CliPaginationRequest request,
  }) async {
    if (loadPage == null && loadNext == null) {
      throw CliFailure.unsupported(
        'Comic source "${source.key}" has no usable list loader.',
        source: source.key,
        operation: operation,
      );
    }
    var cursorMode = loadPage == null;
    request.validate(cursorMode: cursorMode);
    var items = <Comic>[];
    var fetched = 0;
    if (!cursorMode) {
      var current = request.page;
      int? maxPage;
      var hasMore = true;
      while (true) {
        CliExecutionContext.current?.cancellation.throwIfCancelled();
        var res = await loadPage(current);
        var pageItems = await _unwrap(
          res,
          source: source.key,
          operation: operation,
        );
        maxPage = _intOrNull(res.subData) ?? maxPage;
        fetched++;
        var remaining = request.limit == null
            ? null
            : request.limit! - items.length;
        var reachedLimit = _appendWithLimit(items, pageItems, request.limit);
        var truncated = remaining != null && pageItems.length > remaining;
        hasMore =
            truncated ||
            (maxPage == null ? pageItems.isNotEmpty : current < maxPage);
        if (!request.all ||
            reachedLimit ||
            (request.maxPages != null && fetched >= request.maxPages!) ||
            !hasMore ||
            pageItems.isEmpty) {
          break;
        }
        current++;
      }
      return {
        'items': items.map(comicToJson).toList(),
        'pagination': {
          'kind': 'page',
          'page': request.page,
          'maxPage': maxPage,
          'hasMore': hasMore,
          'fetchedPages': fetched,
        },
      };
    }

    var currentCursor = request.cursor;
    String? nextCursor;
    var hasMore = true;
    while (true) {
      CliExecutionContext.current?.cancellation.throwIfCancelled();
      var res = await loadNext!(currentCursor);
      var pageItems = await _unwrap(
        res,
        source: source.key,
        operation: operation,
      );
      nextCursor = res.subData?.toString();
      if (nextCursor?.isEmpty == true) nextCursor = null;
      fetched++;
      var remaining = request.limit == null
          ? null
          : request.limit! - items.length;
      var reachedLimit = _appendWithLimit(items, pageItems, request.limit);
      var truncated = remaining != null && pageItems.length > remaining;
      hasMore = truncated || nextCursor != null;
      if (!request.all ||
          reachedLimit ||
          (request.maxPages != null && fetched >= request.maxPages!) ||
          !hasMore ||
          pageItems.isEmpty) {
        break;
      }
      currentCursor = nextCursor;
    }
    return {
      'items': items.map(comicToJson).toList(),
      'pagination': {
        'kind': 'cursor',
        'cursor': request.cursor,
        'nextCursor': nextCursor,
        'hasMore': hasMore,
        'fetchedPages': fetched,
      },
    };
  }

  static bool _appendWithLimit<T>(List<T> target, List<T> values, int? limit) {
    if (limit == null) {
      target.addAll(values);
      return false;
    }
    var remaining = limit - target.length;
    if (remaining <= 0) return true;
    target.addAll(values.take(remaining));
    return values.length >= remaining;
  }

  static String _encodeSearchOption(SearchOptions schema, Object? value) {
    if (schema.type == 'multi-select' && value is List) {
      return jsonEncode(value.map((item) => item.toString()).toList());
    }
    return value?.toString() ?? '';
  }

  static Future<T> _unwrap<T>(
    Res<T> result, {
    required String source,
    required String operation,
  }) async {
    if (result.success) return result.data;
    var message = result.errorMessage ?? 'Unknown source error.';
    if (message.contains('interactive_required:')) {
      var interactiveMessage = message
          .split('interactive_required:')
          .last
          .trim()
          .split('\n')
          .first;
      throw CliFailure.interactiveRequired(interactiveMessage, source: source);
    }
    if (message == 'Not login' || message.contains('Login expired')) {
      throw CliFailure(
        code: 'login_required',
        message: message,
        exitCode: CliExitCode.authentication,
        source: source,
        operation: operation,
      );
    }
    throw CliFailure.source(message, source: source, operation: operation);
  }

  static Map<String, dynamic> _installationToJson(
    ComicSourceInstallation installation, {
    bool detailed = false,
  }) {
    var source = installation.source;
    var base = <String, dynamic>{
      'key': source?.key ?? _fileNameWithoutExtension(installation.filePath),
      'name': source?.name,
      'version': source?.version,
      'state': switch (installation.state) {
        ComicSourceInstallationState.ready => 'ready',
        ComicSourceInstallationState.disabled => 'disabled',
        ComicSourceInstallationState.parseError => 'parse_error',
        ComicSourceInstallationState.incompatible => 'incompatible',
      },
      'loggedIn': source == null
          ? 'unknown'
          : source.account == null
          ? 'unknown'
          : source.isLogged
          ? 'logged_in'
          : 'logged_out',
      'error': installation.error,
      'capabilities': source == null ? null : sourceCapabilities(source),
    };
    if (detailed && source != null) {
      base.addAll({
        'url': source.url,
        'searchOptions': [
          for (var option in source.searchPageData?.searchOptions ?? const [])
            {
              'label': option.label,
              'type': option.type,
              'default': option.defaultValue,
              'values': option.options,
            },
        ],
        'rankingOptions': source.categoryComicsData?.rankingData?.options,
        'explorePages': [
          for (var index = 0; index < source.explorePages.length; index++)
            {
              'index': index + 1,
              'title': source.explorePages[index].title,
              'type': source.explorePages[index].type.name,
            },
        ],
      });
    }
    return base;
  }

  static Map<String, dynamic> sourceCapabilities(ComicSource source) {
    var favorite = source.favoriteData;
    return {
      'search': source.searchPageData == null
          ? null
          : source.searchPageData!.loadPage != null
          ? 'page'
          : source.searchPageData!.loadNext != null
          ? 'cursor'
          : null,
      'details': source.loadComicInfo != null,
      'categories': source.categoryData != null,
      'categoryComics': source.categoryComicsData != null,
      'ranking': source.categoryComicsData?.rankingData == null
          ? null
          : source.categoryComicsData!.rankingData!.load != null
          ? 'page'
          : source.categoryComicsData!.rankingData!.loadWithNext != null
          ? 'cursor'
          : null,
      'explore': source.explorePages.map((page) => page.type.name).toList(),
      'favorites': favorite == null
          ? null
          : {
              'list': favorite.loadComic != null
                  ? 'page'
                  : favorite.loadNext != null
                  ? 'cursor'
                  : null,
              'modify': favorite.addOrDelFavorite != null,
              'multiFolder': favorite.multiFolder,
              'folderMembership': favorite.loadFolders != null
                  ? 'partial'
                  : 'none',
              'createFolder': favorite.addFolder != null,
              'deleteFolder': favorite.deleteFolder != null,
              'singleFolderForSingleComic': favorite.singleFolderForSingleComic,
              'allFavoritesId': favorite.allFavoritesId,
            },
    };
  }

  static Map<String, dynamic> comicToJson(Comic comic) => {
    'title': comic.title,
    'subtitle': comic.subtitle,
    'cover': comic.cover,
    'id': comic.id,
    'source': comic.sourceKey,
    'tags': comic.tags ?? const <String>[],
    'description': comic.description,
    'maxPage': comic.maxPage,
    'language': comic.language,
    'favoriteId': comic.favoriteId,
    'stars': comic.stars,
  };

  static Map<String, dynamic> comicDetailsToJson(ComicDetails details) => {
    'title': details.title,
    'subtitle': details.subTitle,
    'cover': details.cover,
    'description': details.description,
    'tags': details.tags,
    'chapters': chaptersToJson(details.chapters),
    'thumbnails': details.thumbnails ?? const <String>[],
    'recommendations': details.recommend?.map(comicToJson).toList() ?? const [],
    'source': details.sourceKey,
    'id': details.comicId,
    'isFavorite': details.isFavorite,
    'subId': details.subId,
    'isLiked': details.isLiked,
    'likesCount': details.likesCount,
    'commentCount': details.commentCount,
    'uploader': details.uploader,
    'uploadTime': details.uploadTime,
    'updateTime': details.updateTime,
    'url': details.url,
    'stars': details.stars,
    'maxPage': details.maxPage,
  };

  static List<Map<String, dynamic>> chaptersToJson(ComicChapters? chapters) {
    if (chapters == null) return const [];
    var result = <Map<String, dynamic>>[];
    var overallIndex = 0;
    if (!chapters.isGrouped) {
      for (var entry in chapters.allChapters.entries) {
        result.add({
          'id': entry.key,
          'title': entry.value,
          'index': ++overallIndex,
          'group': null,
          'groupIndex': null,
        });
      }
      return result;
    }
    for (var group in chapters.groups) {
      var groupIndex = 0;
      for (var entry in chapters.getGroup(group).entries) {
        result.add({
          'id': entry.key,
          'title': entry.value,
          'index': ++overallIndex,
          'group': group,
          'groupIndex': ++groupIndex,
        });
      }
    }
    return result;
  }

  static Map<String, dynamic> explorePartToJson(ExplorePagePart part) => {
    'title': part.title,
    'items': part.comics.map(comicToJson).toList(),
    'viewMore': part.viewMore == null
        ? null
        : pageJumpTargetToJson(part.viewMore!),
  };

  static Map<String, dynamic> pageJumpTargetToJson(PageJumpTarget target) => {
    'source': target.sourceKey,
    'type': target.page,
    'attributes': target.attributes,
  };

  static Map<String, dynamic> _sourceIdentity(ComicSource source) => {
    'key': source.key,
    'name': source.name,
    'version': source.version,
  };

  static String _fileNameWithoutExtension(String path) {
    var name = path.split(Platform.pathSeparator).last;
    return name.endsWith('.js') ? name.substring(0, name.length - 3) : name;
  }

  static int? _intOrNull(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
