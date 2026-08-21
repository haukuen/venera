import 'dart:async';
import 'dart:convert';

import 'package:venera/foundation/sensitive_data.dart';

const int cliSchemaVersion = 1;
const int cliProtocolVersion = 1;

abstract final class CliExitCode {
  static const success = 0;
  static const invalidArguments = 2;
  static const authentication = 3;
  static const unsupported = 4;
  static const notFound = 5;
  static const conflict = 6;
  static const partialFailure = 7;
  static const cancelled = 8;
  static const sourceError = 10;
  static const ipcError = 69;
  static const internalError = 70;
}

class CliFailure implements Exception {
  final String code;
  final String message;
  final int exitCode;
  final bool retryable;
  final String? source;
  final String? operation;
  final Map<String, dynamic>? details;
  final Object? data;

  const CliFailure({
    required this.code,
    required this.message,
    required this.exitCode,
    this.retryable = false,
    this.source,
    this.operation,
    this.details,
    this.data,
  });

  factory CliFailure.invalid(String message, {Map<String, dynamic>? details}) {
    return CliFailure(
      code: 'invalid_arguments',
      message: message,
      exitCode: CliExitCode.invalidArguments,
      details: details,
    );
  }

  factory CliFailure.unsupported(
    String message, {
    String? source,
    String? operation,
  }) {
    return CliFailure(
      code: 'unsupported',
      message: message,
      exitCode: CliExitCode.unsupported,
      source: source,
      operation: operation,
    );
  }

  factory CliFailure.notFound(
    String message, {
    String? source,
    String? operation,
  }) {
    return CliFailure(
      code: 'not_found',
      message: message,
      exitCode: CliExitCode.notFound,
      source: source,
      operation: operation,
    );
  }

  factory CliFailure.conflict(
    String code,
    String message, {
    String? source,
    String? operation,
    Map<String, dynamic>? details,
  }) {
    return CliFailure(
      code: code,
      message: message,
      exitCode: CliExitCode.conflict,
      source: source,
      operation: operation,
      details: details,
    );
  }

  factory CliFailure.source(
    String message, {
    required String source,
    required String operation,
    bool retryable = false,
    String code = 'source_error',
    Map<String, dynamic>? details,
  }) {
    return CliFailure(
      code: code,
      message: message,
      exitCode: CliExitCode.sourceError,
      retryable: retryable,
      source: source,
      operation: operation,
      details: details,
    );
  }

  factory CliFailure.cancelled([String message = 'Command cancelled.']) {
    return CliFailure(
      code: 'cancelled',
      message: message,
      exitCode: CliExitCode.cancelled,
    );
  }

  factory CliFailure.interactiveRequired(String message, {String? source}) {
    return CliFailure(
      code: 'interactive_required',
      message: message,
      exitCode: CliExitCode.authentication,
      source: source,
    );
  }

  factory CliFailure.appLocked() {
    return const CliFailure(
      code: 'app_locked',
      message: 'Venera is locked.',
      exitCode: CliExitCode.authentication,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'message': message,
      'retryable': retryable,
      'source': source,
      'operation': operation,
      'details': details,
    };
  }

  @override
  String toString() => '$code: $message';
}

class CliWarning {
  final String code;
  final String message;
  final String? source;
  final Map<String, dynamic>? details;

  const CliWarning({
    required this.code,
    required this.message,
    this.source,
    this.details,
  });

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'source': source,
    'details': details,
  };

  factory CliWarning.fromJson(Map<String, dynamic> json) {
    return CliWarning(
      code: json['code']?.toString() ?? 'warning',
      message: json['message']?.toString() ?? '',
      source: json['source']?.toString(),
      details: json['details'] is Map
          ? Map<String, dynamic>.from(json['details'] as Map)
          : null,
    );
  }
}

class CliEnvelope {
  final bool ok;
  final String command;
  final Object? data;
  final CliFailure? error;
  final List<CliWarning> warnings;
  final Map<String, dynamic> meta;
  final int exitCode;

  const CliEnvelope._({
    required this.ok,
    required this.command,
    required this.data,
    required this.error,
    required this.warnings,
    required this.meta,
    required this.exitCode,
  });

  factory CliEnvelope.success({
    required String command,
    Object? data,
    List<CliWarning> warnings = const [],
    Map<String, dynamic> meta = const {},
  }) {
    return CliEnvelope._(
      ok: true,
      command: command,
      data: data,
      error: null,
      warnings: warnings,
      meta: meta,
      exitCode: CliExitCode.success,
    );
  }

  factory CliEnvelope.failure({
    required String command,
    required CliFailure error,
    List<CliWarning> warnings = const [],
    Map<String, dynamic> meta = const {},
  }) {
    return CliEnvelope._(
      ok: false,
      command: command,
      data: error.data,
      error: error,
      warnings: warnings,
      meta: meta,
      exitCode: error.exitCode,
    );
  }

  factory CliEnvelope.fromJson(Map<String, dynamic> json, {int? exitCode}) {
    var errorJson = json['error'];
    CliFailure? error;
    if (errorJson is Map) {
      var map = Map<String, dynamic>.from(errorJson);
      error = CliFailure(
        code: map['code']?.toString() ?? 'internal_error',
        message: map['message']?.toString() ?? '',
        exitCode: exitCode ?? _exitCodeForError(map['code']?.toString()),
        retryable: map['retryable'] == true,
        source: map['source']?.toString(),
        operation: map['operation']?.toString(),
        details: map['details'] is Map
            ? Map<String, dynamic>.from(map['details'] as Map)
            : null,
        data: json['data'],
      );
    }
    return CliEnvelope._(
      ok: json['ok'] == true,
      command: json['command']?.toString() ?? '',
      data: json['data'],
      error: error,
      warnings: (json['warnings'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => CliWarning.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      meta: json['meta'] is Map
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : const {},
      exitCode: json['ok'] == true
          ? CliExitCode.success
          : error?.exitCode ?? exitCode ?? CliExitCode.internalError,
    );
  }

  Map<String, dynamic> toJson() {
    return Map<String, dynamic>.from(
      CliSanitizer.sanitizeValue({
            'schemaVersion': cliSchemaVersion,
            'ok': ok,
            'command': command,
            'data': data,
            'error': error?.toJson(),
            'warnings': warnings.map((warning) => warning.toJson()).toList(),
            'meta': meta,
          })
          as Map,
    );
  }

  String encode() => jsonEncode(toJson());

  static int _exitCodeForError(String? code) {
    return switch (code) {
      'invalid_arguments' => CliExitCode.invalidArguments,
      'login_required' ||
      'app_locked' ||
      'interactive_required' => CliExitCode.authentication,
      'unsupported' => CliExitCode.unsupported,
      'not_found' => CliExitCode.notFound,
      'state_unknown' ||
      'confirmation_required' ||
      'duplicate_folder_name' ||
      'protected_folder' => CliExitCode.conflict,
      'partial_failure' => CliExitCode.partialFailure,
      'timeout' || 'cancelled' => CliExitCode.cancelled,
      'ipc_error' || 'protocol_mismatch' => CliExitCode.ipcError,
      'internal_error' => CliExitCode.internalError,
      _ => CliExitCode.sourceError,
    };
  }
}

class CliEvent {
  final int id;
  final String type;
  final Object? data;

  const CliEvent(this.id, this.type, this.data);

  Map<String, dynamic> toJson() => {'id': id, 'type': type, 'data': data};
}

class CliCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw CliFailure.cancelled();
  }
}

typedef CliEventSink = void Function(String type, Object? data);

class CliReporter {
  final CliEventSink? _sink;
  final List<CliWarning> warnings = [];

  CliReporter([this._sink]);

  void progress(String message, {Object? data}) {
    _sink?.call('progress', {'message': message, 'data': data});
  }

  void warning(
    String code,
    String message, {
    String? source,
    Map<String, dynamic>? details,
  }) {
    var warning = CliWarning(
      code: code,
      message: message,
      source: source,
      details: details,
    );
    warnings.add(warning);
    _sink?.call('warning', warning.toJson());
  }

  void legacy(Map<String, dynamic> value) {
    _sink?.call('legacy', value);
  }
}

abstract final class CliSanitizer {
  static Object? sanitizeValue(Object? value, {String? key}) {
    return SensitiveDataSanitizer.sanitizeValue(value, key: key);
  }

  static String sanitizeText(String value) {
    return SensitiveDataSanitizer.sanitizeText(value);
  }

  static String sanitizeUrl(String value) {
    return SensitiveDataSanitizer.sanitizeUrl(value);
  }
}
