import 'dart:async';

import 'contract.dart';

enum CliTransport { direct, ipc }

class CliGlobalOptions {
  final bool json;
  final bool allowGui;
  final bool recordHistory;
  final bool quiet;
  final bool noColor;
  final bool ignoreHeadlessLog;
  final Duration timeout;

  const CliGlobalOptions({
    required this.json,
    required this.allowGui,
    required this.recordHistory,
    required this.quiet,
    required this.noColor,
    required this.ignoreHeadlessLog,
    required this.timeout,
  });

  Map<String, dynamic> toJson() => {
    'json': json,
    'allowGui': allowGui,
    'recordHistory': recordHistory,
    'quiet': quiet,
    'noColor': noColor,
    'ignoreHeadlessLog': ignoreHeadlessLog,
    'timeoutMs': timeout.inMilliseconds,
  };

  factory CliGlobalOptions.fromJson(Map<String, dynamic> json) {
    return CliGlobalOptions(
      json: json['json'] == true,
      allowGui: json['allowGui'] == true,
      recordHistory: json['recordHistory'] == true,
      quiet: json['quiet'] == true,
      noColor: json['noColor'] == true,
      ignoreHeadlessLog: json['ignoreHeadlessLog'] == true,
      timeout: Duration(milliseconds: json['timeoutMs'] as int? ?? 120000),
    );
  }
}

class CliExecutionContext {
  static final Object _zoneKey = Object();

  final String requestId;
  final String command;
  final CliGlobalOptions options;
  final CliTransport transport;
  final CliReporter reporter;
  final CliCancellationToken cancellation;
  final bool guiAvailable;
  String? _interactiveRequest;

  CliExecutionContext({
    required this.requestId,
    required this.command,
    required this.options,
    required this.transport,
    required this.reporter,
    required this.cancellation,
    required this.guiAvailable,
  });

  bool get canUseGui => guiAvailable && options.allowGui;

  void markInteractiveRequired(String message) {
    _interactiveRequest ??= message;
  }

  void throwIfInteractiveRequired() {
    var message = _interactiveRequest;
    if (message != null) throw CliInteractiveRequiredException(message);
  }

  static CliExecutionContext? get current {
    return Zone.current[_zoneKey] as CliExecutionContext?;
  }

  Future<T> run<T>(Future<T> Function() body) {
    return runZoned(body, zoneValues: {_zoneKey: this});
  }
}

class CliInteractiveRequiredException implements Exception {
  final String message;

  const CliInteractiveRequiredException(this.message);

  @override
  String toString() => 'interactive_required: $message';
}
