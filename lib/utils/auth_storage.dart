import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

class AuthStorage {
  static String get _path => p.join(App.dataPath, 'auth.json');

  static Map<String, dynamic>? _cache;

  static Future<void> init() async {
    final f = File(_path);
    if (await f.exists()) {
      try {
        final decoded = jsonDecode(await f.readAsString());
        _cache = decoded is Map<String, dynamic> ? decoded : {};
      } catch (e, s) {
        Log.error("AuthStorage", "Failed to read auth.json: $e", s);
        _cache = {};
      }
    } else {
      _cache = {};
    }
  }

  static String? get pinHash => _cache?['pinHash'] as String?;

  static bool get hasPin {
    final hash = _cache?['pinHash'] as String?;
    return hash != null && hash.length == 64;
  }

  static Future<void> setPin(String pin) async {
    final salt = Random.secure()
        .nextInt(0xFFFFFFFF)
        .toRadixString(16)
        .padLeft(8, '0');
    final hash = sha256.convert(utf8.encode(salt + pin)).toString();
    _cache ??= {};
    _cache!['pinHash'] = hash;
    _cache!['pinSalt'] = salt;
    await File(_path).writeAsString(jsonEncode(_cache));
  }

  static Future<void> clearPin() async {
    _cache ??= {};
    _cache!.remove('pinHash');
    _cache!.remove('pinSalt');
    await File(_path).writeAsString(jsonEncode(_cache));
  }

  static bool verifyPin(String pin) {
    final stored = pinHash;
    if (stored == null || stored.isEmpty) return false;
    final salt = _cache?['pinSalt'] as String? ?? '';
    return stored == sha256.convert(utf8.encode(salt + pin)).toString();
  }
}
