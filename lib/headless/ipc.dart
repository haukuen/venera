import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_runner.dart';
import 'contract.dart';
import 'execution_context.dart';
import 'runtime_lock.dart';

typedef CliJobAuthorizer =
    Future<void> Function(
      CliParsedInvocation invocation,
      CliCancellationToken cancellation,
    );

class CliIpcServer {
  final CliRuntimeLease lease;
  final CliCommandRunner runner;
  final CliJobAuthorizer? authorize;
  final _jobs = <String, _CliJob>{};
  final _interactiveJobs = _AsyncMutex();
  HttpServer? _server;
  CliRuntimeDescriptor? descriptor;

  CliIpcServer({required this.lease, required this.runner, this.authorize});

  Future<CliRuntimeDescriptor> start({required String appVersion}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    descriptor = await lease.publish(
      port: _server!.port,
      appVersion: appVersion,
    );
    unawaited(_serve());
    return descriptor!;
  }

  Future<void> close() async {
    for (var job in _jobs.values) {
      if (!job.isComplete) job.cancellation.cancel();
    }
    await _server?.close(force: true);
    await lease.release();
  }

  Future<void> _serve() async {
    await for (var request in _server!) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value('origin') != null) {
        return _json(request.response, HttpStatus.forbidden, {
          'error': 'browser_origins_are_not_allowed',
        });
      }
      var expected = 'Bearer ${descriptor!.token}';
      if (request.headers.value(HttpHeaders.authorizationHeader) != expected) {
        return _json(request.response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
        });
      }
      var segments = request.uri.pathSegments;
      if (request.method == 'GET' &&
          segments.length == 2 &&
          segments[0] == 'v1' &&
          segments[1] == 'health') {
        return _json(request.response, HttpStatus.ok, {
          'protocolVersion': cliProtocolVersion,
          'appVersion': descriptor!.appVersion,
          'pid': pid,
        });
      }
      if (segments.length == 2 &&
          segments[0] == 'v1' &&
          segments[1] == 'jobs' &&
          request.method == 'POST') {
        return _createJob(request);
      }
      if (segments.length >= 3 &&
          segments[0] == 'v1' &&
          segments[1] == 'jobs') {
        var job = _jobs[segments[2]];
        if (job == null) {
          return _json(request.response, HttpStatus.notFound, {
            'error': 'job_not_found',
          });
        }
        if (segments.length == 3 && request.method == 'GET') {
          return _json(request.response, HttpStatus.ok, job.snapshot());
        }
        if (segments.length == 3 && request.method == 'DELETE') {
          job.cancellation.cancel();
          return _json(request.response, HttpStatus.accepted, job.snapshot());
        }
        if (segments.length == 4 &&
            segments[3] == 'events' &&
            request.method == 'GET') {
          return _events(request, job);
        }
      }
      return _json(request.response, HttpStatus.notFound, {
        'error': 'not_found',
      });
    } catch (error) {
      try {
        await _json(request.response, HttpStatus.internalServerError, {
          'error': 'internal_error',
          'message': CliSanitizer.sanitizeText(error.toString()),
        });
      } catch (_) {
        await request.response.close();
      }
    }
  }

  Future<void> _createJob(HttpRequest request) async {
    var body = await utf8.decoder.bind(request).join();
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_json',
      });
    }
    if (decoded is! Map ||
        decoded['requestId'] is! String ||
        decoded['arguments'] is! List) {
      return _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
    }
    var requestId = decoded['requestId'] as String;
    if (!_uuidPattern.hasMatch(requestId)) {
      return _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_request_id',
      });
    }
    var arguments = (decoded['arguments'] as List)
        .map((item) => item.toString())
        .toList();
    var existing = _jobs[requestId];
    if (existing != null) {
      if (!_sameArguments(existing.arguments, arguments)) {
        return _json(request.response, HttpStatus.conflict, {
          'error': 'request_id_conflict',
        });
      }
      return _json(request.response, HttpStatus.ok, existing.snapshot());
    }
    var job = _CliJob(requestId, arguments);
    _jobs[requestId] = job;
    unawaited(_runJob(job));
    return _json(request.response, HttpStatus.accepted, job.snapshot());
  }

  Future<void> _runJob(_CliJob job) async {
    job.emit('accepted', {'requestId': job.requestId});
    CliEnvelope envelope;
    try {
      var invocation = CliCommandRunner.parseInvocation(job.arguments);
      Future<CliEnvelope> execute() async {
        await authorize?.call(invocation, job.cancellation);
        return runner.run(
          invocation: invocation,
          requestId: job.requestId,
          transport: CliTransport.ipc,
          guiAvailable: true,
          cancellation: job.cancellation,
          eventSink: job.emit,
        );
      }

      envelope = invocation.options.allowGui
          ? await _interactiveJobs.run(execute)
          : await execute();
    } on CliFailure catch (error) {
      envelope = CliEnvelope.failure(
        command: 'ipc',
        error: error,
        meta: {
          'appVersion': descriptor!.appVersion,
          'protocolVersion': cliProtocolVersion,
          'transport': 'ipc',
          'partial': false,
          'requestId': job.requestId,
        },
      );
    } catch (error) {
      envelope = CliEnvelope.failure(
        command: 'ipc',
        error: CliFailure(
          code: 'internal_error',
          message: error.toString(),
          exitCode: CliExitCode.internalError,
        ),
        meta: {
          'appVersion': descriptor!.appVersion,
          'protocolVersion': cliProtocolVersion,
          'transport': 'ipc',
          'partial': false,
          'requestId': job.requestId,
        },
      );
    }
    job.complete(envelope);
    Timer(const Duration(minutes: 5), () {
      if (identical(_jobs[job.requestId], job)) _jobs.remove(job.requestId);
      job.close();
    });
  }

  Future<void> _events(HttpRequest request, _CliJob job) async {
    var response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set(HttpHeaders.connectionHeader, 'keep-alive');
    response.bufferOutput = false;
    var lastId =
        int.tryParse(
          request.headers.value('last-event-id') ??
              request.uri.queryParameters['after'] ??
              '-1',
        ) ??
        -1;
    try {
      while (true) {
        var pending = job.events.where((event) => event.id > lastId).toList();
        if (pending.isNotEmpty) {
          for (var event in pending) {
            _writeEvent(response, event);
            lastId = event.id;
          }
          await response.flush();
          if (job.isComplete && lastId >= job.events.last.id) break;
          continue;
        }
        if (job.isComplete) break;
        if (!await job.waitForEventAfter(lastId)) {
          response.write(': keepalive\n\n');
        }
        await response.flush();
      }
    } on SocketException {
      // The job continues and the client can reconnect with Last-Event-ID.
    } finally {
      await response.close();
    }
  }

  static void _writeEvent(HttpResponse response, CliEvent event) {
    response
      ..write('id: ${event.id}\n')
      ..write('event: ${event.type}\n')
      ..write('data: ${jsonEncode(event.data)}\n\n');
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Object value,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(CliSanitizer.sanitizeValue(value)));
    await response.close();
  }

  static bool _sameArguments(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

class CliIpcClient {
  final CliRuntimeDescriptor descriptor;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  CliIpcClient(this.descriptor);

  void close() => _client.close(force: true);

  Future<bool> probe() async {
    if (descriptor.protocolVersion != cliProtocolVersion) return false;
    try {
      var request = await _request('GET', '/v1/health');
      var response = await request.close().timeout(const Duration(seconds: 2));
      if (response.statusCode != HttpStatus.ok) return false;
      var data = jsonDecode(await utf8.decoder.bind(response).join());
      return data is Map && data['protocolVersion'] == cliProtocolVersion;
    } catch (_) {
      return false;
    }
  }

  Future<CliEnvelope> execute({
    required String requestId,
    required List<String> arguments,
    required CliCancellationToken cancellation,
    void Function(String type, Object? data)? onEvent,
  }) async {
    if (descriptor.protocolVersion != cliProtocolVersion) {
      throw CliFailure(
        code: 'protocol_mismatch',
        message:
            'CLI protocol $cliProtocolVersion is incompatible with running protocol ${descriptor.protocolVersion}.',
        exitCode: CliExitCode.ipcError,
      );
    }
    var create = await _request('POST', '/v1/jobs');
    create.headers.contentType = ContentType.json;
    create.write(jsonEncode({'requestId': requestId, 'arguments': arguments}));
    var createResponse = await create.close();
    var createBody = await utf8.decoder.bind(createResponse).join();
    if (createResponse.statusCode != HttpStatus.accepted &&
        createResponse.statusCode != HttpStatus.ok) {
      throw CliFailure(
        code: 'ipc_error',
        message: 'IPC job creation failed (${createResponse.statusCode}).',
        exitCode: CliExitCode.ipcError,
        details: {'response': createBody},
      );
    }
    var cancelSent = false;
    unawaited(
      cancellation.whenCancelled.then((_) async {
        if (cancelSent) return;
        cancelSent = true;
        try {
          var request = await _request('DELETE', '/v1/jobs/$requestId');
          await request.close();
        } catch (_) {
          // The server may already have completed or disappeared.
        }
      }),
    );

    var lastEventId = -1;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        var request = await _request(
          'GET',
          '/v1/jobs/$requestId/events?after=$lastEventId',
        );
        if (lastEventId >= 0) {
          request.headers.set('Last-Event-ID', lastEventId.toString());
        }
        var response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const SocketException('IPC event stream rejected.');
        }
        String? eventType;
        String? eventData;
        await for (var line
            in response
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (line.startsWith('id:')) {
            lastEventId = int.tryParse(line.substring(3).trim()) ?? lastEventId;
          } else if (line.startsWith('event:')) {
            eventType = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            eventData = line.substring(5).trim();
          } else if (line.isEmpty && eventType != null) {
            var data = eventData == null || eventData.isEmpty
                ? null
                : jsonDecode(eventData);
            onEvent?.call(eventType, data);
            if (_terminalEvents.contains(eventType)) {
              if (data is! Map || data['envelope'] is! Map) {
                throw const FormatException('Invalid terminal IPC event.');
              }
              return CliEnvelope.fromJson(
                Map<String, dynamic>.from(data['envelope'] as Map),
                exitCode: data['exitCode'] as int?,
              );
            }
            eventType = null;
            eventData = null;
          }
        }
      } catch (_) {
        if (attempt == 1) rethrow;
      }
    }
    throw CliFailure(
      code: 'ipc_error',
      message: 'IPC event stream ended without a final result.',
      exitCode: CliExitCode.ipcError,
    );
  }

  Future<HttpClientRequest> _request(String method, String path) async {
    var request = await _client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${descriptor.port}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${descriptor.token}',
    );
    return request;
  }

  static const _terminalEvents = {'completed', 'failed', 'cancelled'};
}

class _CliJob {
  final String requestId;
  final List<String> arguments;
  final CliCancellationToken cancellation = CliCancellationToken();
  final List<CliEvent> events = [];
  final StreamController<CliEvent> _events = StreamController.broadcast();
  CliEnvelope? envelope;

  _CliJob(this.requestId, this.arguments);

  bool get isComplete => envelope != null;
  Stream<CliEvent> get stream => _events.stream;

  void emit(String type, Object? data) {
    var event = CliEvent(events.length, type, CliSanitizer.sanitizeValue(data));
    events.add(event);
    _events.add(event);
  }

  void complete(CliEnvelope value) {
    envelope = value;
    var type = value.ok
        ? 'completed'
        : value.error?.code == 'cancelled'
        ? 'cancelled'
        : 'failed';
    emit(type, {'envelope': value.toJson(), 'exitCode': value.exitCode});
  }

  Future<bool> waitForEventAfter(int eventId) async {
    if (events.any((event) => event.id > eventId)) return true;
    var completer = Completer<bool>();
    late StreamSubscription<CliEvent> subscription;
    Timer? timer;
    subscription = stream.listen(
      (event) {
        if (event.id <= eventId || completer.isCompleted) return;
        completer.complete(true);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(true);
      },
    );
    // Recheck after subscribing to close the gap between the first snapshot and
    // stream registration.
    if (events.any((event) => event.id > eventId) && !completer.isCompleted) {
      completer.complete(true);
    }
    timer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) completer.complete(false);
    });
    var result = await completer.future;
    timer.cancel();
    await subscription.cancel();
    return result;
  }

  Map<String, dynamic> snapshot() => {
    'requestId': requestId,
    'state': envelope == null
        ? cancellation.isCancelled
              ? 'cancelling'
              : 'running'
        : envelope!.ok
        ? 'completed'
        : 'failed',
    'lastEventId': events.isEmpty ? null : events.last.id,
    'envelope': envelope?.toJson(),
    'exitCode': envelope?.exitCode,
  };

  void close() {
    _events.close();
  }
}

class _AsyncMutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    var ready = Completer<void>();
    var previous = _tail;
    _tail = ready.future;
    return previous.then((_) => operation()).whenComplete(ready.complete);
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
