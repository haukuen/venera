import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/headless_smoke.dart <venera-binary> <profile>',
    );
    exitCode = 2;
    return;
  }

  var binary = File(arguments[0]).absolute;
  var profile = Directory(arguments[1]).absolute;
  _expect(
    await binary.exists(),
    'Venera binary does not exist: ${binary.path}',
  );
  await _installFixtures(profile);

  var version = await _run(binary, const ['--version']);
  _expect(version['command'] == 'version', 'Version command was not selected.');

  var inventory = await _run(binary, const ['source', 'list']);
  var installations = inventory['data'] as List<dynamic>;
  _expect(
    installations.any(
      (item) =>
          item is Map && item['key'] == 'fake_cli' && item['state'] == 'ready',
    ),
    'The page-based QuickJS fixture was not loaded.',
  );
  _expect(
    installations.any(
      (item) =>
          item is Map &&
          item['key'] == 'fake_broken' &&
          item['state'] == 'parse_error',
    ),
    'A broken QuickJS fixture was not reported as parse_error.',
  );

  var search = await _run(binary, const [
    'comic',
    'search',
    'fixture',
    '--source',
    'fake_cli',
  ]);
  var searchGroup = ((search['data'] as Map)['groups'] as List).single as Map;
  _expect(
    ((searchGroup['items'] as List).single as Map)['id'] == 'fixture-1',
    'Page-based search returned an unexpected comic.',
  );
  _expect(
    (searchGroup['pagination'] as Map)['kind'] == 'page',
    'Page-based search did not report page pagination.',
  );

  var cursorSearch = await _run(binary, const [
    'comic',
    'search',
    'cursor',
    '--source',
    'fake_cursor',
  ]);
  var cursorGroup =
      ((cursorSearch['data'] as Map)['groups'] as List).single as Map;
  _expect(
    (cursorGroup['pagination'] as Map)['kind'] == 'cursor',
    'Cursor search did not report cursor pagination.',
  );

  var details = await _run(binary, const [
    'comic',
    'show',
    '--source',
    'fake_cli',
    '--id',
    'alpha',
  ]);
  var detailData = details['data'] as Map;
  _expect(detailData['commentCount'] == 7, 'Comment count was not retained.');
  _expect(
    !detailData.containsKey('comments'),
    'Comment content must not be exposed by the CLI DTO.',
  );

  var categories = await _run(binary, const [
    'category',
    'list',
    '--source',
    'fake_cli',
  ]);
  _expect(
    (categories['data'] as List).isNotEmpty,
    'Category discovery failed.',
  );

  var rankings = await _run(binary, const [
    'ranking',
    'list',
    '--source',
    'fake_cli',
  ]);
  _expect((rankings['data'] as List).length == 2, 'Ranking discovery failed.');

  var explore = await _run(binary, const [
    'explore',
    'show',
    '--source',
    'fake_cli',
    '--title',
    'Mixed fixture',
    '--limit',
    '1',
  ]);
  var blocks = (((explore['data'] as Map)['content'] as Map)['blocks'] as List);
  var exploredComics = blocks.fold<int>(
    0,
    (count, block) => count + (((block as Map)['items'] as List).length),
  );
  _expect(exploredComics == 1, 'Mixed explore did not honor --limit.');

  var folders = await _run(binary, const [
    'favorite',
    'remote',
    'folder',
    'list',
    '--source',
    'fake_cli',
  ]);
  var folderItems = folders['data'] as List;
  _expect(
    folderItems.any(
      (item) =>
          item is Map &&
          item['id'] == 'all' &&
          item['isAllFavorites'] == true &&
          item['synthetic'] == true,
    ),
    'The declared aggregate favorite folder was not synthesized.',
  );

  var status = await _run(binary, const [
    'favorite',
    'remote',
    'status',
    '--source',
    'fake_cli',
    '--id',
    'alpha',
  ]);
  _expect(
    (status['data'] as Map)['state'] == 'favorited',
    'Favorite status discovery failed.',
  );

  var add = await _run(binary, const [
    'favorite',
    'remote',
    'add',
    '--source',
    'fake_cli',
    '--id',
    'beta',
    '--folder',
    'keep',
    '--favorite-id',
    'fixture-favorite-id',
  ]);
  _expect(
    (add['data'] as Map)['verification'] == 'verified',
    'Favorite add was not verified after the write.',
  );

  var createFolder = await _run(binary, const [
    'favorite',
    'remote',
    'folder',
    'create',
    '--source',
    'fake_cli',
    '--name',
    'Created by smoke test',
  ]);
  _expect(
    (createFolder['data'] as Map)['verification'] == 'verified',
    'Favorite folder creation was not verified after the write.',
  );

  var deleteFolder = await _run(binary, const [
    'favorite',
    'remote',
    'folder',
    'delete',
    '--source',
    'fake_cli',
    '--folder',
    'empty',
    '--yes',
  ]);
  _expect(
    (deleteFolder['data'] as Map)['verification'] == 'verified',
    'Favorite folder deletion was not verified after the write.',
  );

  var interactive = await _run(
    binary,
    const ['comic', 'search', 'needs-ui', '--source', 'fake_cursor'],
    expectedExitCode: 3,
    expectSuccess: false,
  );
  _expect(
    (interactive['error'] as Map)['code'] == 'interactive_required',
    'QuickJS input did not fail with interactive_required.',
  );

  var fireAndForgetInteractive = await _run(
    binary,
    const ['comic', 'search', 'fire-and-forget-ui', '--source', 'fake_cursor'],
    expectedExitCode: 3,
    expectSuccess: false,
  );
  _expect(
    (fireAndForgetInteractive['error'] as Map)['code'] ==
        'interactive_required',
    'A non-awaited QuickJS dialog did not fail with interactive_required.',
  );

  stdout.writeln('Headless QuickJS smoke test passed.');
}

Future<void> _installFixtures(Directory profile) async {
  var fixtures = Directory('test/fixtures/headless').absolute;
  _expect(await fixtures.exists(), 'Fixture directory does not exist.');
  var destination = Directory(
    '${profile.path}${Platform.pathSeparator}comic_source',
  );
  await destination.create(recursive: true);
  await for (var entity in fixtures.list()) {
    if (entity is! File) continue;
    var name = entity.uri.pathSegments.last;
    await entity.copy('${destination.path}${Platform.pathSeparator}$name');
  }
}

Future<Map<String, dynamic>> _run(
  File binary,
  List<String> arguments, {
  int expectedExitCode = 0,
  bool expectSuccess = true,
}) async {
  var result = await Process.run(binary.path, [
    '--headless',
    '--json',
    '--quiet',
    '--no-color',
    ...arguments,
  ]);
  var lines = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().isNotEmpty)
      .toList();
  _expect(
    lines.length == 1,
    'Expected exactly one JSON object on stdout for ${arguments.join(' ')}, got ${lines.length}.\n'
    'stdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
  Map<String, dynamic> envelope;
  try {
    envelope = Map<String, dynamic>.from(jsonDecode(lines.single) as Map);
  } on Object catch (error) {
    throw StateError(
      'Invalid JSON for ${arguments.join(' ')}: $error\n${lines.single}',
    );
  }
  _expect(
    result.exitCode == expectedExitCode,
    'Unexpected exit code for ${arguments.join(' ')}: '
    '${result.exitCode} (expected $expectedExitCode).\n${result.stderr}',
  );
  _expect(
    envelope['schemaVersion'] == 1 && envelope['ok'] == expectSuccess,
    'Unexpected envelope for ${arguments.join(' ')}: ${jsonEncode(envelope)}',
  );
  return envelope;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
