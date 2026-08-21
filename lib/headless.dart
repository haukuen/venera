import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/contract.dart';
import 'package:venera/headless/execution_context.dart';
import 'package:venera/headless/ipc.dart';
import 'package:venera/headless/runtime_lock.dart';
import 'package:venera/init.dart';

const _legacyCommands = {'webdav', 'updatescript', 'updatesubscribe'};

/// Runs one `--headless` invocation and returns its process exit code.
///
/// This function deliberately does not call [exit], which keeps it testable.
/// The executable entry point is responsible for terminating after streams are
/// flushed.
Future<int> runHeadlessMode(List<String> processArguments) async {
  var marker = processArguments.indexOf('--headless');
  var arguments = marker < 0
      ? List<String>.from(processArguments)
      : processArguments.sublist(marker + 1);
  CliParsedInvocation invocation;
  try {
    invocation = CliCommandRunner.parseInvocation(arguments);
  } on CliFailure catch (error) {
    var envelope = _failureEnvelope(error, arguments);
    var output = _HeadlessOutput.fromRaw(arguments);
    output.finish(envelope);
    return output.exitCode(envelope);
  }

  var output = _HeadlessOutput(invocation);
  var runner = CliCommandRunner();
  if (invocation.options.json || invocation.options.ignoreHeadlessLog) {
    Log.isMuted = true;
  }

  // Help, version, and parser-level errors must remain usable even when the app
  // profile or Flutter plugins cannot be initialized.
  if (invocation.help ||
      invocation.version ||
      invocation.commandArguments.isEmpty) {
    var envelope = await runner.run(
      invocation: invocation,
      transport: CliTransport.direct,
      guiAvailable: false,
    );
    output.finish(envelope);
    return output.exitCode(envelope);
  }
  try {
    CliCommandRunner.commandParser.parse(invocation.commandArguments);
  } on FormatException catch (error) {
    var envelope = _failureEnvelope(
      CliFailure.invalid(error.message),
      invocation.commandArguments,
    );
    output.finish(envelope);
    return output.exitCode(envelope);
  }

  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux || Platform.isMacOS) {
    var userHome = Platform.environment['HOME'];
    if (userHome != null && userHome.isNotEmpty) Directory.current = userHome;
  }

  var cancellation = CliCancellationToken();
  StreamSubscription<ProcessSignal>? signalSubscription;
  var interruptCount = 0;
  try {
    signalSubscription = ProcessSignal.sigint.watch().listen((_) {
      interruptCount++;
      if (interruptCount == 1) {
        cancellation.cancel();
        if (!invocation.options.quiet) {
          stderr.writeln(
            'Cancellation requested; waiting for a safe boundary.',
          );
        }
      } else {
        exit(130);
      }
    });
  } on UnsupportedError {
    // The runner timeout and normal cancellation path remain available.
  }

  CliRuntimeLease? lease;
  CliEnvelope envelope;
  try {
    await App.init();
    var routed = await _tryRunningGui(
      arguments: arguments,
      cancellation: cancellation,
      output: output,
    );
    if (routed != null) {
      envelope = routed;
    } else {
      lease = await CliRuntimeLock.tryAcquire();
      if (lease == null) {
        envelope = await _waitForGui(
          arguments: arguments,
          invocation: invocation,
          cancellation: cancellation,
          output: output,
        );
      } else {
        await lease.clearStaleDescriptor();
        await init();
        if (appdata.settings['authorizationRequired'] == true) {
          envelope = CliEnvelope.failure(
            command: CliCommandRunner.commandName(invocation.commandArguments),
            error: CliFailure.appLocked(),
            meta: _meta(CliTransport.direct),
          );
        } else {
          envelope = await runner.run(
            invocation: invocation,
            transport: CliTransport.direct,
            guiAvailable: false,
            cancellation: cancellation,
            eventSink: output.event,
          );
        }
      }
    }
  } on CliFailure catch (error) {
    envelope = CliEnvelope.failure(
      command: CliCommandRunner.commandName(invocation.commandArguments),
      error: error,
      meta: _meta(CliTransport.direct),
    );
  } catch (error) {
    envelope = CliEnvelope.failure(
      command: CliCommandRunner.commandName(invocation.commandArguments),
      error: CliFailure(
        code: 'internal_error',
        message: error.toString(),
        exitCode: CliExitCode.internalError,
      ),
      meta: _meta(CliTransport.direct),
    );
  } finally {
    await lease?.release();
    await signalSubscription?.cancel();
  }

  output.finish(envelope);
  return output.exitCode(envelope);
}

Future<CliEnvelope?> _tryRunningGui({
  required List<String> arguments,
  required CliCancellationToken cancellation,
  required _HeadlessOutput output,
}) async {
  var descriptor = await CliRuntimeLock.readDescriptor();
  if (descriptor == null) return null;
  if (descriptor.protocolVersion != cliProtocolVersion) {
    // A stale descriptor is harmless if the lock can be acquired. Defer the
    // mismatch decision until the caller observes that another owner exists.
    return null;
  }
  var client = CliIpcClient(descriptor);
  try {
    if (!await client.probe()) return null;
    return await client.execute(
      requestId: const Uuid().v4(),
      arguments: arguments,
      cancellation: cancellation,
      onEvent: output.event,
    );
  } finally {
    client.close();
  }
}

Future<CliEnvelope> _waitForGui({
  required List<String> arguments,
  required CliParsedInvocation invocation,
  required CliCancellationToken cancellation,
  required _HeadlessOutput output,
}) async {
  var waitMs = invocation.options.timeout.inMilliseconds.clamp(1, 5000);
  var deadline = DateTime.now().add(Duration(milliseconds: waitMs));
  do {
    cancellation.throwIfCancelled();
    var descriptor = await CliRuntimeLock.readDescriptor();
    if (descriptor != null) {
      if (descriptor.protocolVersion != cliProtocolVersion) {
        throw CliFailure(
          code: 'protocol_mismatch',
          message:
              'CLI protocol $cliProtocolVersion is incompatible with the running Venera protocol ${descriptor.protocolVersion}.',
          exitCode: CliExitCode.ipcError,
        );
      }
      var client = CliIpcClient(descriptor);
      try {
        if (await client.probe()) {
          return await client.execute(
            requestId: const Uuid().v4(),
            arguments: arguments,
            cancellation: cancellation,
            onEvent: output.event,
          );
        }
      } finally {
        client.close();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  } while (DateTime.now().isBefore(deadline));
  throw CliFailure(
    code: 'ipc_error',
    message:
        'Another Venera runtime owns the profile but its IPC endpoint is unavailable.',
    exitCode: CliExitCode.ipcError,
  );
}

class _HeadlessOutput {
  final CliParsedInvocation invocation;
  bool _legacyErrorPrinted = false;

  _HeadlessOutput(this.invocation);

  factory _HeadlessOutput.fromRaw(List<String> arguments) {
    var options = CliGlobalOptions(
      json: arguments.contains('--json'),
      allowGui: arguments.contains('--allow-gui'),
      recordHistory: arguments.contains('--record-history'),
      quiet: arguments.contains('--quiet'),
      noColor: arguments.contains('--no-color'),
      ignoreHeadlessLog: arguments.contains('--ignore-disheadless-log'),
      timeout: const Duration(minutes: 2),
    );
    return _HeadlessOutput(
      CliParsedInvocation(
        commandArguments: arguments,
        options: options,
        help: arguments.contains('--help') || arguments.contains('-h'),
        version: arguments.contains('--version'),
      ),
    );
  }

  bool get isLegacy {
    var first = invocation.commandArguments.firstOrNull;
    return first != null && _legacyCommands.contains(first);
  }

  void event(String type, Object? rawData) {
    var data = CliSanitizer.sanitizeValue(rawData);
    if (type == 'legacy' && data is Map) {
      if (data['status'] == 'error') _legacyErrorPrinted = true;
      if (!invocation.options.json) {
        stdout.writeln('[CLI PRINT] ${jsonEncode(data)}');
      } else if (!invocation.options.quiet) {
        stderr.writeln('[legacy] ${jsonEncode(data)}');
      }
      return;
    }
    if (type == 'progress' && !invocation.options.quiet) {
      var message = data is Map ? data['message'] : data;
      if (message != null) {
        stderr.writeln(CliSanitizer.sanitizeText('$message'));
      }
      return;
    }
    if (type == 'warning' && data is Map) {
      var code = data['code'] ?? 'warning';
      var message = data['message'] ?? '';
      stderr.writeln('warning [$code]: $message');
    }
  }

  void finish(CliEnvelope envelope) {
    if (invocation.options.json) {
      stdout.writeln(envelope.encode());
      return;
    }
    if (isLegacy) {
      if (!envelope.ok && !_legacyErrorPrinted) {
        stdout.writeln(
          '[CLI PRINT] ${jsonEncode({'status': 'error', 'message': envelope.error?.message ?? 'Unknown error.'})}',
        );
      }
      return;
    }
    if (!envelope.ok) {
      var error = envelope.error!;
      stderr.writeln(_styled('error [${error.code}]: ${error.message}', 31));
      if (error.details != null) {
        stderr.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(CliSanitizer.sanitizeValue(error.details)),
        );
      }
      return;
    }
    if (envelope.command == 'help') {
      stdout.write((envelope.data as Map)['usage']);
    } else if (envelope.command == 'version') {
      stdout.writeln('venera ${(envelope.data as Map)['version']}');
    } else if (envelope.data != null) {
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(CliSanitizer.sanitizeValue(envelope.data)),
      );
    }
  }

  int exitCode(CliEnvelope envelope) {
    if (isLegacy && !invocation.options.json) return envelope.ok ? 0 : 1;
    return envelope.exitCode;
  }

  String _styled(String value, int color) {
    if (invocation.options.noColor || !stderr.hasTerminal) return value;
    return '\u001b[${color}m$value\u001b[0m';
  }
}

CliEnvelope _failureEnvelope(CliFailure error, List<String> arguments) {
  return CliEnvelope.failure(
    command: CliCommandRunner.commandName(arguments),
    error: error,
    meta: _meta(CliTransport.direct),
  );
}

Map<String, dynamic> _meta(CliTransport transport) => {
  'appVersion': App.isInitialized ? App.version : cliAppVersion,
  'protocolVersion': cliProtocolVersion,
  'transport': transport.name,
  'partial': false,
  'requestId': const Uuid().v4(),
};

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
