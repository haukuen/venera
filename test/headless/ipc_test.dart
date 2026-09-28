import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/contract.dart';
import 'package:venera/headless/execution_context.dart';
import 'package:venera/headless/ipc.dart';
import 'package:venera/headless/runtime_lock.dart';

void main() {
  late Directory profile;
  CliIpcServer? server;
  CliRuntimeLease? lease;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('venera-ipc-test-');
    App
      ..dataPath = profile.path
      ..cachePath = '${profile.path}/cache'
      ..version = 'test'
      ..isInitialized = true;
  });

  tearDown(() async {
    if (server != null) {
      await server!.close();
    } else {
      await lease?.release();
    }
    server = null;
    lease = null;
    await profile.delete(recursive: true);
  });

  Future<CliRuntimeDescriptor> start({CliCommandRunner? runner}) async {
    lease = await CliRuntimeLock.tryAcquire();
    expect(lease, isNotNull);
    server = CliIpcServer(lease: lease!, runner: runner ?? CliCommandRunner());
    return server!.start(appVersion: 'test');
  }

  test('runtime files are private', () async {
    var descriptor = await start();

    expect(descriptor.token, hasLength(greaterThanOrEqualTo(43)));
    if (!Platform.isWindows) {
      var directoryMode = (await CliRuntimeLock.directory.stat()).mode & 0x1ff;
      var descriptorMode =
          (await CliRuntimeLock.descriptorFile.stat()).mode & 0x1ff;
      expect(directoryMode, 0x1c0); // 0700
      expect(descriptorMode, 0x180); // 0600
    }
  });

  test('runtime lock excludes another process', () async {
    if (Platform.isWindows) return;
    await CliRuntimeLock.directory.create(recursive: true);
    await CliRuntimeLock.lockFile.create(recursive: true);
    var process = await Process.start('python3', [
      '-c',
      'import fcntl,sys; f=open(sys.argv[1], "a+"); '
          'fcntl.lockf(f, fcntl.LOCK_EX); print("ready", flush=True); '
          'sys.stdin.read()',
      CliRuntimeLock.lockFile.path,
    ]);
    addTearDown(() {
      process.kill();
    });
    var ready = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    expect(ready, 'ready');

    var blocked = await CliRuntimeLock.tryAcquire();

    expect(blocked, isNull);
    await process.stdin.close();
    expect(await process.exitCode, 0);
  });

  test('runtime lock is not re-entrant in one process', () async {
    lease = await CliRuntimeLock.tryAcquire();
    expect(lease, isNotNull);

    var second = await CliRuntimeLock.tryAcquire();

    expect(second, isNull);
  });

  test('rejects missing bearer token and browser origins', () async {
    var descriptor = await start();
    var http = HttpClient();
    addTearDown(() => http.close(force: true));

    var unauthorized = await http.getUrl(
      Uri.parse('http://127.0.0.1:${descriptor.port}/v1/health'),
    );
    var unauthorizedResponse = await unauthorized.close();
    var unauthorizedBody = await utf8.decoder.bind(unauthorizedResponse).join();
    expect(unauthorizedResponse.statusCode, HttpStatus.unauthorized);
    expect(unauthorizedBody, isNot(contains(descriptor.token)));

    var origin = await http.getUrl(
      Uri.parse('http://127.0.0.1:${descriptor.port}/v1/health'),
    );
    origin.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${descriptor.token}')
      ..set('Origin', 'https://example.test');
    var originResponse = await origin.close();
    expect(originResponse.statusCode, HttpStatus.forbidden);
  });

  test('client handshake and SSE return a schema-versioned result', () async {
    var descriptor = await start();
    var client = CliIpcClient(descriptor);
    addTearDown(client.close);

    expect(await client.probe(), isTrue);
    var events = <String>[];
    var result = await client.execute(
      requestId: const Uuid().v4(),
      arguments: const ['--version', '--json'],
      cancellation: CliCancellationToken(),
      onEvent: (type, data) => events.add(type),
    );

    expect(result.ok, isTrue);
    expect(result.command, 'version');
    expect(result.meta['transport'], 'ipc');
    expect(events, containsAllInOrder(['accepted', 'completed']));
  });

  test(
    'request IDs are idempotent but cannot be reused for other arguments',
    () async {
      var descriptor = await start();
      var requestId = const Uuid().v4();

      var first = await _postJob(descriptor, requestId, const ['--version']);
      expect(first.$1, HttpStatus.accepted);
      var same = await _postJob(descriptor, requestId, const ['--version']);
      expect(same.$1, HttpStatus.ok);
      var conflict = await _postJob(descriptor, requestId, const ['--help']);
      expect(conflict.$1, HttpStatus.conflict);
      expect(conflict.$2['error'], 'request_id_conflict');
    },
  );

  test(
    'cancellation is propagated through DELETE and terminal SSE event',
    () async {
      var descriptor = await start(runner: _BlockingRunner());
      var client = CliIpcClient(descriptor);
      addTearDown(client.close);
      var cancellation = CliCancellationToken();
      Timer(const Duration(milliseconds: 30), cancellation.cancel);

      var result = await client.execute(
        requestId: const Uuid().v4(),
        arguments: const ['source', 'list'],
        cancellation: cancellation,
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'cancelled');
      expect(result.exitCode, CliExitCode.cancelled);
    },
  );

  test('stale descriptor is removed only after acquiring the lock', () async {
    lease = await CliRuntimeLock.tryAcquire();
    expect(lease, isNotNull);
    await CliRuntimeLock.descriptorFile.writeAsString('{"stale":true}');

    await lease!.clearStaleDescriptor();

    expect(await CliRuntimeLock.descriptorFile.exists(), isFalse);
  });
}

Future<(int, Map<String, dynamic>)> _postJob(
  CliRuntimeDescriptor descriptor,
  String requestId,
  List<String> arguments,
) async {
  var client = HttpClient();
  try {
    var request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${descriptor.port}/v1/jobs'),
    );
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${descriptor.token}');
    request.write(jsonEncode({'requestId': requestId, 'arguments': arguments}));
    var response = await request.close();
    var body = jsonDecode(await utf8.decoder.bind(response).join());
    return (response.statusCode, Map<String, dynamic>.from(body as Map));
  } finally {
    client.close(force: true);
  }
}

class _BlockingRunner extends CliCommandRunner {
  @override
  Future<CliEnvelope> run({
    required CliParsedInvocation invocation,
    String? requestId,
    required CliTransport transport,
    required bool guiAvailable,
    CliEventSink? eventSink,
    CliCancellationToken? cancellation,
  }) async {
    await cancellation!.whenCancelled;
    return CliEnvelope.failure(
      command: 'source.list',
      error: CliFailure.cancelled(),
      meta: {
        'appVersion': 'test',
        'protocolVersion': cliProtocolVersion,
        'transport': transport.name,
        'partial': false,
        'requestId': requestId,
      },
    );
  }
}
