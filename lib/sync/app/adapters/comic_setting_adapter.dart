/// App adapter for the `comicSetting` domain (protocol v2 §3).
///
/// The app stores per-comic reader settings in
/// `appdata.settings['comicSpecificSettings']`, keyed by
/// `"<comicId>@<sourceKey>"`, with a JSON map per comic. M3 projects the whole
/// per-comic map as one LWW register:
///
///   key  `[comicKey, ""]` (`SyncKeys.comicSettingKey(comicKey, '')`, the empty
///        setting-key segment is reserved for a future per-setting register),
///   data `{"settings": {<settingKey>: <value>, ...}}`.
///
/// The adapter is callback-injected (like `SettingsAdapter`) so it stays pure
/// Dart and is testable with a plain map instead of the Flutter app singleton.
library;

import 'dart:convert';

import '../../domains.dart';
import '../../key_codec.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

class ComicSettingAdapter implements SyncAppAdapter {
  ComicSettingAdapter({
    required Map<String, Object?> Function() readComicSettings,
    required void Function(String comicKey, Object? value) set,
    required Future<void> Function() persist,
    Future<void> Function()? reload,
    void Function(String message)? onWarning,
  }) : _readComicSettings = readComicSettings,
       _set = set,
       _persist = persist,
       _reload = reload,
       _onWarning = onWarning;

  final Map<String, Object?> Function() _readComicSettings;
  final void Function(String comicKey, Object? value) _set;
  final Future<void> Function() _persist;
  final Future<void> Function()? _reload;
  final void Function(String message)? _onWarning;

  static const Set<String> _domains = <String>{SyncDomains.comicSetting};

  @override
  Set<String> get domains => _domains;

  /// Projects one register per comic key.
  ///
  /// Empty comic keys and values that are not JSON-encodable maps are skipped
  /// with a warning; they must never enter the wire protocol.
  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final records = <AdapterRecord>[];
    for (final entry in _readComicSettings().entries) {
      final comicKey = entry.key;
      if (comicKey.isEmpty) {
        _warn('comicSetting: skipping empty comic key');
        continue;
      }
      final settings = _asSettingsMap(entry.value);
      if (settings == null) {
        _warn('comicSetting: skipping "$comicKey" with non-map settings');
        continue;
      }
      if (!_isJsonEncodable(settings)) {
        _warn('comicSetting: skipping "$comicKey" with non-encodable settings');
        continue;
      }
      final SyncKey key;
      try {
        key = SyncKeys.comicSettingKey(comicKey, '');
      } catch (error) {
        _warn('comicSetting: skipping invalid comic key "$comicKey": $error');
        continue;
      }
      records.add(
        AdapterRecord(
          domain: SyncDomains.comicSetting,
          key: key,
          field: '',
          kind: SyncOpKind.upsert,
          data: <String, Object?>{'settings': settings},
        ),
      );
    }
    return records;
  }

  /// Applies visible per-comic registers.
  ///
  /// Only comics that have a store record are written; local entries without a
  /// remote record are never deleted (forward compatibility). [persist] and
  /// [reload] run only when at least one local map actually changed.
  ///
  /// Malformed records (unexpected key shape, non-map payload) are reported
  /// through [onWarning] and skipped; one bad record never aborts the merge.
  @override
  Future<void> applyRemote(SyncStore store) async {
    final stored = await store.dumpRecords(domains: _domains);
    final current = _readComicSettings();
    var changed = 0;
    for (final record in stored) {
      if (!record.visible) continue;
      if (record.field.isNotEmpty) {
        _warn(
          'comicSetting: ignoring record with unexpected field '
          '"${record.field}" for ${record.key.encode()}',
        );
        continue;
      }
      final comicKey = _comicKeyOf(record.key);
      if (comicKey == null) {
        _warn(
          'comicSetting: ignoring record with unexpected key '
          '${record.key.encode()}',
        );
        continue;
      }
      final data = record.data;
      final settings = data == null ? null : _asSettingsMap(data['settings']);
      if (settings == null) {
        _warn('comicSetting: ignoring record without settings for "$comicKey"');
        continue;
      }
      if (_jsonEquals(current[comicKey], settings)) continue;
      try {
        _set(comicKey, settings);
        changed++;
      } catch (error) {
        _warn('comicSetting: failed to set "$comicKey": $error');
      }
    }
    if (changed == 0) return;
    await _persist();
    await _reload?.call();
  }

  @override
  Future<void> reload() async {
    await _reload?.call();
  }

  /// Extracts the comic key from a store key.
  ///
  /// The canonical form is `[comicKey, '']`; a bare `[comicKey]` is also
  /// accepted for forward compatibility. Keys whose reserved second segment is
  /// non-empty are a different (future per-setting) shape and are ignored.
  String? _comicKeyOf(SyncKey key) {
    final parts = key.parts;
    if (parts.length == 1) return parts[0].isEmpty ? null : parts[0];
    if (parts.length == 2 && parts[1].isEmpty && parts[0].isNotEmpty) {
      return parts[0];
    }
    return null;
  }

  /// Copies the appdata value into a plain JSON map. `null` means "not a
  /// settings map" (malformed payload or projection).
  Map<String, Object?>? _asSettingsMap(Object? value) {
    if (value is! Map) return null;
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) return null;
      result[key] = entry.value;
    }
    return result;
  }

  static bool _jsonEquals(Object? existing, Object? remote) {
    try {
      return jsonEncode(existing) == jsonEncode(remote);
    } catch (_) {
      return false;
    }
  }

  static bool _isJsonEncodable(Object? value) {
    try {
      jsonEncode(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _warn(String message) => _onWarning?.call(message);
}
