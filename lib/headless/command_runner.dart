import 'dart:async';
import 'dart:convert';

import 'package:args/args.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

import 'contract.dart';
import 'execution_context.dart';
import 'favorite_service.dart';
import 'legacy_service.dart';
import 'source_coordinator.dart';
import 'source_service.dart';

const String cliAppVersion = '1.15.0';

class CliParsedInvocation {
  final List<String> commandArguments;
  final CliGlobalOptions options;
  final bool help;
  final bool version;

  const CliParsedInvocation({
    required this.commandArguments,
    required this.options,
    required this.help,
    required this.version,
  });
}

class CliCommandRunner {
  final CliSourceService sources;
  final CliFavoriteService favorites;
  final LegacyHeadlessService legacy;
  final SourceOperationCoordinator coordinator;

  CliCommandRunner({
    this.sources = const CliSourceService(),
    CliFavoriteService? favorites,
    this.legacy = const LegacyHeadlessService(),
    SourceOperationCoordinator? coordinator,
  }) : coordinator = coordinator ?? SourceOperationCoordinator.instance,
       favorites =
           favorites ??
           CliFavoriteService(sources: sources, coordinator: coordinator);

  static final ArgParser commandParser = _buildCommandParser();

  static String commandName(List<String> arguments) {
    try {
      var path = _commandPath(commandParser.parse(arguments));
      return path.isEmpty ? 'help' : path.join('.');
    } on FormatException {
      return _commandHint(arguments);
    }
  }

  static CliParsedInvocation parseInvocation(List<String> rawArguments) {
    var globalTokens = <String>[];
    var commandTokens = <String>[];
    var afterTerminator = false;
    for (var index = 0; index < rawArguments.length; index++) {
      var token = rawArguments[index];
      if (afterTerminator) {
        commandTokens.add(token);
        continue;
      }
      if (token == '--') {
        afterTerminator = true;
        commandTokens.add(token);
        continue;
      }
      if (_globalBooleanOptions.contains(token)) {
        globalTokens.add(token);
        continue;
      }
      if (token == '--timeout') {
        globalTokens.add(token);
        if (++index >= rawArguments.length) {
          throw CliFailure.invalid('--timeout requires a value.');
        }
        globalTokens.add(rawArguments[index]);
        continue;
      }
      if (token.startsWith('--timeout=')) {
        globalTokens.add(token);
        continue;
      }
      commandTokens.add(token);
    }

    ArgResults globals;
    try {
      globals = _globalParser.parse(globalTokens);
    } on FormatException catch (error) {
      throw CliFailure.invalid(error.message);
    }
    return CliParsedInvocation(
      commandArguments: commandTokens,
      options: CliGlobalOptions(
        json: globals.flag('json'),
        allowGui: globals.flag('allow-gui'),
        recordHistory: globals.flag('record-history'),
        quiet: globals.flag('quiet'),
        noColor: globals.flag('no-color'),
        ignoreHeadlessLog: globals.flag('ignore-disheadless-log'),
        timeout: _parseDuration(globals.option('timeout')!),
      ),
      help: globals.flag('help'),
      version: globals.flag('version'),
    );
  }

  Future<CliEnvelope> run({
    required CliParsedInvocation invocation,
    String? requestId,
    required CliTransport transport,
    required bool guiAvailable,
    CliEventSink? eventSink,
    CliCancellationToken? cancellation,
  }) async {
    var id = requestId ?? const Uuid().v4();
    var reporter = CliReporter(eventSink);
    var token = cancellation ?? CliCancellationToken();
    if (invocation.version) {
      return CliEnvelope.success(
        command: 'version',
        data: {
          'name': 'venera',
          'version': cliAppVersion,
          'schemaVersion': cliSchemaVersion,
          'protocolVersion': cliProtocolVersion,
        },
        meta: _meta(id, transport),
      );
    }

    ArgResults parsed;
    try {
      parsed = commandParser.parse(invocation.commandArguments);
    } on FormatException catch (error) {
      return CliEnvelope.failure(
        command: _commandHint(invocation.commandArguments),
        error: CliFailure.invalid(error.message),
        meta: _meta(id, transport),
      );
    }
    var path = _commandPath(parsed);
    var commandName = path.isEmpty ? 'help' : path.join('.');
    if (invocation.help || path.isEmpty) {
      return CliEnvelope.success(
        command: commandName,
        data: {'usage': usage},
        meta: _meta(id, transport),
      );
    }

    var context = CliExecutionContext(
      requestId: id,
      command: commandName,
      options: invocation.options,
      transport: transport,
      reporter: reporter,
      cancellation: token,
      guiAvailable: guiAvailable,
    );
    var timedOut = false;
    var timer = Timer(invocation.options.timeout, () {
      timedOut = true;
      token.cancel();
    });
    try {
      var data = await context.run(
        () => _dispatch(path, _leaf(parsed), invocation.options),
      );
      context.throwIfInteractiveRequired();
      var writeFinishedAfterCancellation = reporter.warnings.any(
        (warning) => warning.code == 'cancellation_after_dispatch',
      );
      if (timedOut && !writeFinishedAfterCancellation) {
        throw CliFailure(
          code: 'timeout',
          message: 'Command timed out.',
          exitCode: CliExitCode.cancelled,
        );
      }
      if (token.isCancelled && !writeFinishedAfterCancellation) {
        throw CliFailure.cancelled();
      }
      return CliEnvelope.success(
        command: commandName,
        data: data,
        warnings: List.unmodifiable(reporter.warnings),
        meta: _meta(id, transport, partial: _isPartial(data)),
      );
    } on CliFailure catch (error) {
      return CliEnvelope.failure(
        command: commandName,
        error: error,
        warnings: List.unmodifiable(reporter.warnings),
        meta: _meta(
          id,
          transport,
          partial: error.code == 'partial_failure' || _isPartial(error.data),
        ),
      );
    } on CliInteractiveRequiredException catch (error) {
      return CliEnvelope.failure(
        command: commandName,
        error: CliFailure.interactiveRequired(error.message),
        warnings: List.unmodifiable(reporter.warnings),
        meta: _meta(id, transport),
      );
    } catch (error) {
      return CliEnvelope.failure(
        command: commandName,
        error: CliFailure(
          code: 'internal_error',
          message: error.toString(),
          exitCode: CliExitCode.internalError,
        ),
        warnings: List.unmodifiable(reporter.warnings),
        meta: _meta(id, transport),
      );
    } finally {
      timer.cancel();
    }
  }

  Future<Object?> _dispatch(
    List<String> path,
    ArgResults args,
    CliGlobalOptions globals,
  ) async {
    switch (path.join('.')) {
      case 'webdav.up':
        _requireNoPositionals(args);
        return legacy.webdav(true);
      case 'webdav.down':
        _requireNoPositionals(args);
        return legacy.webdav(false);
      case 'updatescript.all':
        _requireNoPositionals(args);
        return legacy.updateScripts();
      case 'updatesubscribe':
        var comicId = args.option('update-comic-by-id-type');
        String? sourceKey;
        if (comicId == null) {
          _requireNoPositionals(args);
        } else {
          if (args.rest.length != 1) {
            throw CliFailure.invalid(
              '--update-comic-by-id-type requires <id> <type>.',
            );
          }
          sourceKey = args.rest.single;
        }
        return legacy.updateSubscribed(comicId: comicId, sourceKey: sourceKey);
      case 'source.list':
        _requireNoPositionals(args);
        return sources.listSources();
      case 'source.show':
        return sources.showSource(_onePositional(args, 'source key'));
      case 'comic.search':
        return _search(args, globals);
      case 'comic.show':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.showComic(
            _required(args, 'source'),
            _required(args, 'id'),
          ),
        );
      case 'comic.chapters':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.comicChapters(
            _required(args, 'source'),
            _required(args, 'id'),
          ),
        );
      case 'comic.tags':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.comicTags(
            _required(args, 'source'),
            _required(args, 'id'),
          ),
        );
      case 'category.list':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.listCategories(_required(args, 'source')),
        );
      case 'category.options':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.categoryOptions(
            sourceKey: _required(args, 'source'),
            category: _required(args, 'category'),
            param: args.option('param'),
          ),
        );
      case 'category.comics':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.categoryComics(
            sourceKey: _required(args, 'source'),
            category: _required(args, 'category'),
            param: args.option('param'),
            fullOptions: _decodeListOption(args.option('options-json')),
            overrides: _optionOverrides(args.multiOption('option')),
            pagination: _pagination(args),
          ),
        );
      case 'ranking.list':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () async => sources.rankingOptions(_required(args, 'source')),
        );
      case 'ranking.comics':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.rankingComics(
            sourceKey: _required(args, 'source'),
            rankingOption: args.option('ranking'),
            pagination: _pagination(args),
          ),
        );
      case 'explore.list':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () async => sources.listExplorePages(_required(args, 'source')),
        );
      case 'explore.show':
        _requireNoPositionals(args);
        return coordinator.query(
          _required(args, 'source'),
          () => sources.showExplorePage(
            sourceKey: _required(args, 'source'),
            index: _intOption(args, 'index'),
            title: args.option('title'),
            pagination: _pagination(args),
          ),
        );
      case 'favorite.remote.list':
        _requireNoPositionals(args);
        return favorites.listFavorites(
          sourceKey: _required(args, 'source'),
          folderId: args.option('folder'),
          pagination: _pagination(args),
        );
      case 'favorite.remote.status':
        _requireNoPositionals(args);
        return favorites.status(
          sourceKey: _required(args, 'source'),
          comicId: _required(args, 'id'),
        );
      case 'favorite.remote.add':
      case 'favorite.remote.remove':
        _requireNoPositionals(args);
        var add = path.last == 'add';
        return add
            ? favorites.add(
                sourceKey: _required(args, 'source'),
                comicId: _required(args, 'id'),
                folderId: args.option('folder'),
                favoriteId: args.option('favorite-id'),
                dryRun: args.flag('dry-run'),
                verifyMaxPages: _intOption(args, 'verify-max-pages') ?? 3,
              )
            : favorites.remove(
                sourceKey: _required(args, 'source'),
                comicId: _required(args, 'id'),
                folderId: args.option('folder'),
                favoriteId: args.option('favorite-id'),
                dryRun: args.flag('dry-run'),
                verifyMaxPages: _intOption(args, 'verify-max-pages') ?? 3,
              );
      case 'favorite.remote.folder.list':
        _requireNoPositionals(args);
        return favorites.listFolders(_required(args, 'source'));
      case 'favorite.remote.folder.create':
        _requireNoPositionals(args);
        return favorites.createFolder(
          sourceKey: _required(args, 'source'),
          name: _required(args, 'name'),
          dryRun: args.flag('dry-run'),
        );
      case 'favorite.remote.folder.delete':
        _requireNoPositionals(args);
        return favorites.deleteFolder(
          sourceKey: _required(args, 'source'),
          folderId: _required(args, 'folder'),
          yes: args.flag('yes'),
          forceNonEmpty: args.flag('force-non-empty'),
          dryRun: args.flag('dry-run'),
        );
      default:
        throw CliFailure.invalid('Unknown command: ${path.join(' ')}');
    }
  }

  Future<Object> _search(ArgResults args, CliGlobalOptions globals) async {
    var keyword = _onePositional(args, 'search query');
    var requested = args.multiOption('source');
    var selected = sources.resolveSearchSources(
      requested: requested,
      allSources: args.flag('all-sources'),
    );
    if (globals.recordHistory) appdata.addSearchHistory(keyword);
    var multiple = selected.length > 1;
    if (multiple && (args.wasParsed('page') || args.wasParsed('cursor'))) {
      throw CliFailure.invalid(
        '--page and --cursor are only available for a single source.',
      );
    }
    if (multiple &&
        (args.wasParsed('option') || args.wasParsed('options-json'))) {
      throw CliFailure.invalid(
        'Use --source-options-json when searching multiple sources.',
      );
    }
    Map<String, dynamic> sourceOptions = {};
    var encodedSourceOptions = args.option('source-options-json');
    if (encodedSourceOptions != null) {
      var decoded = _decodeJson(encodedSourceOptions, '--source-options-json');
      if (decoded is! Map) {
        throw CliFailure.invalid('--source-options-json must be an object.');
      }
      sourceOptions = Map<String, dynamic>.from(decoded);
    }
    var pagination = multiple
        ? CliPaginationRequest(
            all: args.flag('all'),
            maxPages: _intOption(args, 'max-pages-per-source'),
            limit: _intOption(args, 'limit-per-source'),
          )
        : _pagination(args);
    if (multiple &&
        pagination.all &&
        pagination.maxPages == null &&
        pagination.limit == null) {
      throw CliFailure.invalid(
        'Aggregated --all requires --max-pages-per-source or --limit-per-source.',
      );
    }

    var results = await Future.wait([
      for (var source in selected)
        coordinator.query(source.key, () async {
          try {
            List<dynamic>? full;
            if (multiple) {
              var value = sourceOptions[source.key];
              if (value != null && value is! List) {
                throw CliFailure.invalid(
                  'Options for ${source.key} must be a JSON array.',
                );
              }
              full = value as List?;
            } else {
              full = _decodeListOption(args.option('options-json'));
            }
            var options = sources.resolveSearchOptions(
              source,
              fullOptions: full,
              overrides: multiple
                  ? const {}
                  : _optionOverrides(args.multiOption('option')),
            );
            var data = await sources.search(
              source: source,
              keyword: keyword,
              options: options,
              pagination: pagination,
            );
            return _SearchOutcome.success(source.key, data);
          } on CliFailure catch (error) {
            return _SearchOutcome.failure(source.key, error);
          }
        }),
    ]);
    var successes = results.where((result) => result.data != null).toList();
    var failures = results.where((result) => result.error != null).toList();
    var data = {
      'query': keyword,
      'groups': successes.map((result) => result.data).toList(),
      'failures': [
        for (var failure in failures)
          {'source': failure.source, 'error': failure.error!.toJson()},
      ],
    };
    if (failures.isNotEmpty) {
      if (successes.isEmpty) {
        if (!multiple) throw failures.single.error!;
        throw CliFailure(
          code: 'aggregate_failure',
          message: 'Every selected comic source failed.',
          exitCode: CliExitCode.sourceError,
          data: data,
        );
      }
      if (!args.flag('allow-partial')) {
        throw CliFailure(
          code: 'partial_failure',
          message: 'Some comic sources failed.',
          exitCode: CliExitCode.partialFailure,
          data: data,
        );
      }
      for (var failure in failures) {
        CliExecutionContext.current?.reporter.warning(
          'source_failed',
          failure.error!.message,
          source: failure.source,
        );
      }
      data['partial'] = true;
    } else {
      data['partial'] = false;
    }
    return data;
  }

  static CliPaginationRequest _pagination(ArgResults args) {
    return CliPaginationRequest(
      page: _intOption(args, 'page') ?? 1,
      cursor: args.option('cursor'),
      all: args.flag('all'),
      maxPages: _intOption(args, 'max-pages'),
      limit: _intOption(args, 'limit'),
    );
  }

  static Map<int, String> _optionOverrides(List<String> encoded) {
    var result = <int, String>{};
    for (var item in encoded) {
      var separator = item.indexOf('=');
      if (separator <= 0) {
        throw CliFailure.invalid(
          'Option overrides must use INDEX=VALUE syntax.',
        );
      }
      var index = int.tryParse(item.substring(0, separator));
      if (index == null || index < 0) {
        throw CliFailure.invalid('Invalid option index in "$item".');
      }
      result[index] = item.substring(separator + 1);
    }
    return result;
  }

  static List<dynamic>? _decodeListOption(String? encoded) {
    if (encoded == null) return null;
    var decoded = _decodeJson(encoded, '--options-json');
    if (decoded is! List) {
      throw CliFailure.invalid('--options-json must be an array.');
    }
    return decoded;
  }

  static dynamic _decodeJson(String encoded, String option) {
    try {
      return jsonDecode(encoded);
    } on FormatException catch (error) {
      throw CliFailure.invalid('$option is invalid JSON: ${error.message}');
    }
  }

  static String _required(ArgResults args, String name) {
    var value = args.option(name);
    if (value == null || value.isEmpty) {
      throw CliFailure.invalid('--$name is required.');
    }
    return value;
  }

  static int? _intOption(ArgResults args, String name) {
    var value = args.option(name);
    if (value == null) return null;
    var parsed = int.tryParse(value);
    if (parsed == null) {
      throw CliFailure.invalid('--$name must be an integer.');
    }
    return parsed;
  }

  static String _onePositional(ArgResults args, String label) {
    if (args.rest.length != 1) {
      throw CliFailure.invalid('Exactly one $label is required.');
    }
    return args.rest.single;
  }

  static void _requireNoPositionals(ArgResults args) {
    if (args.rest.isNotEmpty) {
      throw CliFailure.invalid(
        'Unexpected positional arguments: ${args.rest.join(' ')}',
      );
    }
  }

  static bool _isPartial(Object? data) {
    return data is Map && data['partial'] == true;
  }

  static Map<String, dynamic> _meta(
    String requestId,
    CliTransport transport, {
    bool partial = false,
  }) {
    return {
      'appVersion': App.isInitialized ? App.version : cliAppVersion,
      'protocolVersion': cliProtocolVersion,
      'transport': transport.name,
      'partial': partial,
      'requestId': requestId,
    };
  }

  static String get usage => '''
Venera headless comic-source CLI

Usage: venera --headless [global options] <resource> <command> [options]

Resources:
  webdav up|down (legacy)
  updatescript all (legacy)
  updatesubscribe (legacy)
  source list|show
  comic search|show|chapters|tags
  category list|options|comics
  ranking list|comics
  explore list|show
  favorite remote list|status|add|remove
  favorite remote folder list|create|delete

Global options:
  --json                    Print one schema-versioned JSON result.
  --timeout <duration>      Command timeout (default: 2m).
  --allow-gui               Permit source-requested UI in a running GUI.
  --record-history          Record search terms in GUI history.
  --quiet                   Suppress progress output.
  --no-color                Disable ANSI colors.
  --help, -h                Show help without initializing Venera.
  --version                 Show version without initializing Venera.
''';
}

class _SearchOutcome {
  final String source;
  final Map<String, dynamic>? data;
  final CliFailure? error;

  const _SearchOutcome._(this.source, this.data, this.error);

  factory _SearchOutcome.success(String source, Map<String, dynamic> data) {
    return _SearchOutcome._(source, data, null);
  }

  factory _SearchOutcome.failure(String source, CliFailure error) {
    return _SearchOutcome._(source, null, error);
  }
}

final _globalParser = ArgParser()
  ..addFlag('json', negatable: false)
  ..addOption('timeout', defaultsTo: '2m')
  ..addFlag('allow-gui', negatable: false)
  ..addFlag('record-history', negatable: false)
  ..addFlag('quiet', negatable: false)
  ..addFlag('no-color', negatable: false)
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('version', negatable: false)
  ..addFlag('ignore-disheadless-log', negatable: false);

const _globalBooleanOptions = {
  '--json',
  '--allow-gui',
  '--record-history',
  '--quiet',
  '--no-color',
  '--help',
  '-h',
  '--version',
  '--ignore-disheadless-log',
};

Duration _parseDuration(String value) {
  var match = RegExp(r'^(\d+)(ms|s|m|h)?$').firstMatch(value.trim());
  if (match == null) {
    throw CliFailure.invalid(
      'Invalid duration "$value". Use milliseconds, s, m, or h.',
    );
  }
  var amount = int.parse(match.group(1)!);
  if (amount < 1) throw CliFailure.invalid('Timeout must be positive.');
  return switch (match.group(2)) {
    'ms' => Duration(milliseconds: amount),
    'm' => Duration(minutes: amount),
    'h' => Duration(hours: amount),
    _ => Duration(seconds: amount),
  };
}

ArgParser _buildCommandParser() {
  var root = ArgParser(allowTrailingOptions: true);

  var webdav = root.addCommand('webdav');
  webdav.addCommand('up');
  webdav.addCommand('down');
  root.addCommand('updatescript').addCommand('all');
  root.addCommand('updatesubscribe').addOption('update-comic-by-id-type');

  var source = root.addCommand('source');
  source.addCommand('list');
  source.addCommand('show');

  var comic = root.addCommand('comic');
  var search = comic.addCommand('search');
  search
    ..addMultiOption('source', abbr: 's')
    ..addFlag('all-sources', negatable: false)
    ..addMultiOption('option')
    ..addOption('options-json')
    ..addOption('source-options-json')
    ..addFlag('allow-partial', negatable: false);
  _addPagination(search, aggregate: true);
  for (var name in ['show', 'chapters', 'tags']) {
    comic.addCommand(name)
      ..addOption('source')
      ..addOption('id');
  }

  var category = root.addCommand('category');
  category.addCommand('list').addOption('source');
  category.addCommand('options')
    ..addOption('source')
    ..addOption('category')
    ..addOption('param');
  var categoryComics = category.addCommand('comics')
    ..addOption('source')
    ..addOption('category')
    ..addOption('param')
    ..addMultiOption('option')
    ..addOption('options-json');
  _addPagination(categoryComics);

  var ranking = root.addCommand('ranking');
  ranking.addCommand('list').addOption('source');
  var rankingComics = ranking.addCommand('comics')
    ..addOption('source')
    ..addOption('ranking');
  _addPagination(rankingComics);

  var explore = root.addCommand('explore');
  explore.addCommand('list').addOption('source');
  var exploreShow = explore.addCommand('show')
    ..addOption('source')
    ..addOption('index')
    ..addOption('title');
  _addPagination(exploreShow);

  var favorite = root.addCommand('favorite');
  var remote = favorite.addCommand('remote');
  var favoriteList = remote.addCommand('list')
    ..addOption('source')
    ..addOption('folder');
  _addPagination(favoriteList);
  remote.addCommand('status')
    ..addOption('source')
    ..addOption('id');
  for (var name in ['add', 'remove']) {
    remote.addCommand(name)
      ..addOption('source')
      ..addOption('id')
      ..addOption('folder')
      ..addOption('favorite-id')
      ..addFlag('dry-run', negatable: false)
      ..addOption('verify-max-pages', defaultsTo: '3');
  }
  var folder = remote.addCommand('folder');
  folder.addCommand('list').addOption('source');
  folder.addCommand('create')
    ..addOption('source')
    ..addOption('name')
    ..addFlag('dry-run', negatable: false);
  folder.addCommand('delete')
    ..addOption('source')
    ..addOption('folder')
    ..addFlag('yes', negatable: false)
    ..addFlag('force-non-empty', negatable: false)
    ..addFlag('dry-run', negatable: false);
  return root;
}

void _addPagination(ArgParser parser, {bool aggregate = false}) {
  parser
    ..addOption('page')
    ..addOption('cursor')
    ..addFlag('all', negatable: false)
    ..addOption('max-pages')
    ..addOption('limit');
  if (aggregate) {
    parser
      ..addOption('max-pages-per-source')
      ..addOption('limit-per-source');
  }
}

List<String> _commandPath(ArgResults root) {
  var result = <String>[];
  ArgResults current = root;
  while (current.command != null) {
    current = current.command!;
    if (current.name != null) result.add(current.name!);
  }
  return result;
}

ArgResults _leaf(ArgResults root) {
  var current = root;
  while (current.command != null) {
    current = current.command!;
  }
  return current;
}

String _commandHint(List<String> arguments) {
  return arguments
      .where((argument) => !argument.startsWith('-'))
      .take(4)
      .join('.');
}
