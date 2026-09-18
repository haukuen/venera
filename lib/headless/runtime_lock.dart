import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:venera/foundation/app.dart';

import 'contract.dart';

class CliRuntimeDescriptor {
  final int pid;
  final int port;
  final int protocolVersion;
  final String appVersion;
  final String token;

  const CliRuntimeDescriptor({
    required this.pid,
    required this.port,
    required this.protocolVersion,
    required this.appVersion,
    required this.token,
  });

  factory CliRuntimeDescriptor.fromJson(Map<String, dynamic> json) {
    return CliRuntimeDescriptor(
      pid: json['pid'] as int,
      port: json['port'] as int,
      protocolVersion: json['protocolVersion'] as int,
      appVersion: json['appVersion'] as String,
      token: json['token'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'pid': pid,
    'port': port,
    'protocolVersion': protocolVersion,
    'appVersion': appVersion,
    'token': token,
  };
}

class CliRuntimeLease {
  final RandomAccessFile _lockFile;
  final Directory directory;
  final File descriptorFile;
  final void Function() _onRelease;
  bool _released = false;
  String? _descriptorToken;

  CliRuntimeLease._(
    this._lockFile,
    this.directory,
    this.descriptorFile,
    this._onRelease,
  );

  Future<CliRuntimeDescriptor> publish({
    required int port,
    required String appVersion,
  }) async {
    var token = _generateToken();
    var descriptor = CliRuntimeDescriptor(
      pid: pid,
      port: port,
      protocolVersion: cliProtocolVersion,
      appVersion: appVersion,
      token: token,
    );
    var temporary = File('${descriptorFile.path}.tmp.$pid');
    await temporary.writeAsString(jsonEncode(descriptor.toJson()), flush: true);
    await _restrictFile(temporary);
    if (Platform.isWindows && await descriptorFile.exists()) {
      await descriptorFile.delete();
    }
    await temporary.rename(descriptorFile.path);
    await _restrictFile(descriptorFile);
    _descriptorToken = token;
    return descriptor;
  }

  /// Removes a descriptor left by a crashed owner after this process has
  /// acquired the authoritative file lock.
  Future<void> clearStaleDescriptor() async {
    if (_descriptorToken != null || !await descriptorFile.exists()) return;
    await descriptorFile.delete();
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      if (_descriptorToken != null && await descriptorFile.exists()) {
        try {
          var current = CliRuntimeDescriptor.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(await descriptorFile.readAsString()) as Map,
            ),
          );
          if (current.token == _descriptorToken) {
            await descriptorFile.delete();
          }
        } catch (_) {
          // A malformed descriptor is left for the next lock owner to replace.
        }
      }
      await _lockFile.unlock();
    } finally {
      try {
        await _lockFile.close();
      } finally {
        _onRelease();
      }
    }
  }

  static String _generateToken() {
    var random = Random.secure();
    var bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

abstract final class CliRuntimeLock {
  static bool _claimedInProcess = false;

  static Directory get directory => Directory('${App.dataPath}/.runtime');
  static File get descriptorFile => File('${directory.path}/ipc.json');
  static File get lockFile => File('${directory.path}/runtime.lock');

  static Future<CliRuntimeDescriptor?> readDescriptor() async {
    try {
      if (!await descriptorFile.exists()) return null;
      var decoded = jsonDecode(await descriptorFile.readAsString());
      if (decoded is! Map) return null;
      return CliRuntimeDescriptor.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static Future<CliRuntimeLease?> tryAcquire() async {
    if (_claimedInProcess) return null;
    _claimedInProcess = true;
    RandomAccessFile? file;
    try {
      await directory.create(recursive: true);
      await _restrictDirectory(directory);
      file = await lockFile.open(mode: FileMode.append);
      await file.lock(FileLock.exclusive);
      await _restrictFile(lockFile);
      return CliRuntimeLease._(file, directory, descriptorFile, () {
        _claimedInProcess = false;
      });
    } on FileSystemException {
      await file?.close();
      _claimedInProcess = false;
      return null;
    } catch (_) {
      await file?.close();
      _claimedInProcess = false;
      rethrow;
    }
  }

  static Future<CliRuntimeLease?> waitForLease(Duration timeout) async {
    var deadline = DateTime.now().add(timeout);
    do {
      var lease = await tryAcquire();
      if (lease != null) return lease;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    return null;
  }
}

Future<void> _restrictDirectory(Directory directory) async {
  if (Platform.isWindows) {
    await _restrictWindows(directory.path, directory: true);
  } else {
    await Process.run('chmod', ['700', directory.path]);
  }
}

Future<void> _restrictFile(File file) async {
  if (Platform.isWindows) {
    await _restrictWindows(file.path, directory: false);
  } else {
    await Process.run('chmod', ['600', file.path]);
  }
}

Future<void> _restrictWindows(String path, {required bool directory}) async {
  var user = Platform.environment['USERNAME'];
  if (user == null || user.isEmpty) {
    throw const FileSystemException(
      'Cannot restrict runtime files without USERNAME.',
    );
  }
  var permission = directory ? '$user:(OI)(CI)F' : '$user:F';
  var result = await Process.run('icacls', [
    path,
    '/inheritance:r',
    '/grant:r',
    permission,
  ]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Failed to restrict runtime file permissions.',
      path,
    );
  }
}
