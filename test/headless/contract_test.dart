import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/sensitive_data.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/contract.dart';
import 'package:venera/headless/execution_context.dart';
import 'package:venera/headless/source_service.dart';

void main() {
  group('CLI contract', () {
    test('version is available before app initialization', () async {
      var invocation = CliCommandRunner.parseInvocation(const ['--version']);
      var result = await CliCommandRunner().run(
        invocation: invocation,
        transport: CliTransport.direct,
        guiAvailable: false,
      );

      expect(result.ok, isTrue);
      expect(result.command, 'version');
      expect((result.data as Map)['version'], cliAppVersion);
      expect(result.toJson()['schemaVersion'], cliSchemaVersion);
    });

    test('headless version stays synchronized with pubspec', () async {
      var pubspec = await File('pubspec.yaml').readAsString();
      var version = RegExp(
        r'^version:\s*([^+\s]+)',
        multiLine: true,
      ).firstMatch(pubspec)!.group(1);
      expect(cliAppVersion, version);
    });

    test('global options can appear before or after a command', () {
      var invocation = CliCommandRunner.parseInvocation(const [
        'comic',
        'search',
        '--json',
        'query',
        '--timeout',
        '5s',
        '--quiet',
      ]);

      expect(invocation.commandArguments, ['comic', 'search', 'query']);
      expect(invocation.options.json, isTrue);
      expect(invocation.options.quiet, isTrue);
      expect(invocation.options.timeout, const Duration(seconds: 5));
    });

    test('command names exclude option values', () {
      expect(
        CliCommandRunner.commandName(const [
          'comic',
          'show',
          '--source',
          'fake',
          '--id',
          'comic',
        ]),
        'comic.show',
      );
    });

    test('JSON envelope keeps null fields and stable top-level keys', () {
      var envelope = CliEnvelope.success(
        command: 'test',
        data: {'nullable': null},
        meta: const {
          'appVersion': 'test',
          'protocolVersion': 1,
          'transport': 'direct',
          'partial': false,
          'requestId': 'request',
        },
      );
      var decoded = jsonDecode(envelope.encode()) as Map<String, dynamic>;

      expect(decoded.keys, [
        'schemaVersion',
        'ok',
        'command',
        'data',
        'error',
        'warnings',
        'meta',
      ]);
      expect((decoded['data'] as Map)['nullable'], isNull);
      expect(decoded['error'], isNull);
    });

    test('comic details expose comment count but not comment content', () {
      var details = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': null,
        'cover': 'https://example.test/cover',
        'description': null,
        'tags': <String, List<String>>{},
        'chapters': null,
        'sourceKey': 'fake',
        'comicId': 'comic',
        'commentCount': 1,
        'comments': [
          {'userName': 'user', 'content': 'must not leak', 'id': 'comment'},
        ],
      });

      var json = CliSourceService.comicDetailsToJson(details);
      expect(json['commentCount'], 1);
      expect(json, isNot(contains('comments')));
      expect(jsonEncode(json), isNot(contains('must not leak')));
    });
  });

  group('sensitive output redaction', () {
    test('redacts structured secrets and URL query credentials', () {
      var sanitized =
          SensitiveDataSanitizer.sanitizeValue({
                'authorization': 'Bearer abc',
                'nested': {
                  'cover':
                      'https://user:pass@example.test/a.jpg?width=400&auth=abc&signature=def',
                  'session_id': 'session-secret',
                },
              })
              as Map;

      expect(sanitized['authorization'], '[REDACTED]');
      var cover = (sanitized['nested'] as Map)['cover'] as String;
      expect(cover, contains('width=400'));
      expect(cover, isNot(contains('abc')));
      expect(cover, isNot(contains('def')));
      expect(cover, isNot(contains('user')));
      expect(cover, isNot(contains('pass')));
      expect((sanitized['nested'] as Map)['session_id'], '[REDACTED]');
    });

    test('redacts free-form bearer and assignments', () {
      var value = SensitiveDataSanitizer.sanitizeText(
        'Authorization: Bearer abc.def token=secret-value',
      );
      expect(value, isNot(contains('abc.def')));
      expect(value, isNot(contains('secret-value')));
      expect(value, contains('[REDACTED]'));
    });
  });
}
