import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/io.dart';

class AuthStorage {
  static String get _path => p.join(App.dataPath, 'auth.json');

  static Map<String, dynamic>? _cache;

  static Future<void> init() async {
    final f = File(_path);
    if (await f.exists()) {
      try {
        _cache = jsonDecode(await f.readAsString());
      } catch (_) {
        _cache = {};
      }
    } else {
      _cache = {};
    }
  }

  static String? get pinHash => _cache?['pinHash'] as String?;

  static bool get hasPin => pinHash != null;

  static Future<void> setPin(String pin) async {
    final hash = sha256.convert(utf8.encode(pin)).toString();
    _cache ??= {};
    _cache!['pinHash'] = hash;
    await File(_path).writeAsString(jsonEncode(_cache));
  }

  static Future<void> clearPin() async {
    _cache ??= {};
    _cache!.remove('pinHash');
    await File(_path).writeAsString(jsonEncode(_cache));
  }

  static bool verifyPin(String pin) {
    final stored = pinHash;
    if (stored == null) return false;
    return stored == sha256.convert(utf8.encode(pin)).toString();
  }
}
