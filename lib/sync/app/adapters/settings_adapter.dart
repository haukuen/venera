/// Projects the app's global settings into the `setting` sync domain
/// (protocol v2 §3, device-local keys §3.2).
///
/// The adapter is callback-injected instead of importing `Appdata`/`Settings`,
/// so it stays pure Dart and can be unit tested without the Flutter app
/// singleton. The app wires it with the known settings key list plus the
/// `appdata.settings[key]` accessors and `appdata.saveData()` as `persist`.
library;

import 'dart:convert';

import '../../domains.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

class SettingsAdapter implements SyncAppAdapter {
  SettingsAdapter({
    required Set<String> Function() keys,
    required Object? Function(String key) get,
    required void Function(String key, Object? value) set,
    required Future<void> Function() persist,
    Future<void> Function()? reload,
    void Function(String message)? onWarning,
  }) : _keys = keys,
       _get = get,
       _set = set,
       _persist = persist,
       _reload = reload,
       _onWarning = onWarning;

  final Set<String> Function() _keys;
  final Object? Function(String key) _get;
  final void Function(String key, Object? value) _set;
  final Future<void> Function() _persist;
  final Future<void> Function()? _reload;
  final void Function(String message)? _onWarning;

  static const Set<String> _domains = <String>{SyncDomains.setting};

  @override
  Set<String> get domains => _domains;

  /// Projects every syncable, JSON-encodable, non-null setting.
  ///
  /// Device-local keys (§3.2), `null` values and values that cannot be
  /// JSON-encoded are skipped: they must never enter the wire protocol.
  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final records = <AdapterRecord>[];
    for (final key in _keys()) {
      if (SyncSettingKeys.isDeviceLocalSetting(key)) continue;
      final value = _get(key);
      if (value == null) continue;
      if (!_isJsonEncodable(value)) continue;
      records.add(
        AdapterRecord(
          domain: SyncDomains.setting,
          key: SyncKeys.settingKey(key),
          field: '',
          kind: SyncOpKind.upsert,
          data: <String, Object?>{'value': value},
        ),
      );
    }
    return records;
  }

  /// Applies the merged setting registers that are currently visible.
  ///
  /// Only registers already present in the store are applied: local keys that
  /// have no remote record are left untouched (forward compatibility, and the
  /// app may know settings this protocol version does not). Device-local keys
  /// are ignored even if a malformed/legacy record carries them, so a remote
  /// device can never flip e.g. [SyncSettingKeys.syncAuthEnabled] (§3.2).
  ///
  /// Malformed records are reported through [onWarning] and skipped; one bad
  /// record never aborts the merge. [persist] and [reload] run only when at
  /// least one setting was actually applied.
  @override
  Future<void> applyRemote(SyncStore store) async {
    final stored = await store.dumpRecords(domains: _domains);
    var applied = 0;
    for (final record in stored) {
      if (!record.visible) continue;
      if (record.field.isNotEmpty) {
        _warn(
          'setting: ignoring record with unexpected field '
          '"${record.field}" for ${record.key.encode()}',
        );
        continue;
      }
      final parts = record.key.parts;
      if (parts.length != 1) {
        _warn('setting: ignoring malformed key ${record.key.encode()}');
        continue;
      }
      final key = parts.first;
      if (SyncSettingKeys.isDeviceLocalSetting(key)) {
        _warn('setting: ignoring device-local key "$key" from store');
        continue;
      }
      final data = record.data;
      if (data == null || !data.containsKey('value')) {
        _warn('setting: ignoring record without value for "$key"');
        continue;
      }
      final value = data['value'];
      if (value == null) {
        // The read side never emits null values; skip instead of clearing a
        // local setting from a non-conforming writer.
        _warn('setting: ignoring null value for "$key"');
        continue;
      }
      try {
        _set(key, value);
        applied++;
      } catch (error) {
        _warn('setting: failed to set "$key": $error');
      }
    }
    if (applied == 0) return;
    await _persist();
    await _reload?.call();
  }

  @override
  Future<void> reload() async {
    await _reload?.call();
  }

  @override
  bool retainsMissingRecord(StoredRecord record) => false;

  @override
  Future<bool> retainsDomainRecords(SyncStore store, String domain) async =>
      false;

  void _warn(String message) => _onWarning?.call(message);

  static bool _isJsonEncodable(Object? value) {
    try {
      jsonEncode(value);
      return true;
    } catch (_) {
      return false;
    }
  }
}
