import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/sync/app/sync_v2_service.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// Status snapshot consumed by the home sync card.
class DataSyncStatusSnapshot {
  const DataSyncStatusSnapshot({
    required this.isEnabled,
    required this.isUploading,
    required this.isDownloading,
    required this.lastSyncTime,
    required this.lastError,
  });

  final bool isEnabled;
  final bool isUploading;
  final bool isDownloading;
  final int lastSyncTime;
  final String? lastError;

  bool get isSyncing => isUploading || isDownloading;

  bool get shouldShow => isEnabled || isSyncing;

  String get title => isSyncing ? 'Syncing Data' : 'Sync Data';

  String get formattedLastSyncTime => _formatTime(lastSyncTime);

  static String _formatTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

typedef WebDavProbe = Future<void> Function(List<String> config);

/// Configuration validation + connectivity probe (kept for the settings page
/// and tests; v2 transport reuses the same normalized config).
class WebDavConnectionTester {
  const WebDavConnectionTester._();

  static List<String>? normalizeConfig(
    Object? config, {
    bool allowEmpty = false,
  }) {
    if (config is! List) return null;
    if (config.isEmpty) return allowEmpty ? const [] : null;
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    final result = config.cast<String>().map((e) => e.trim()).toList();
    if (result.first.isEmpty) return null;
    return result;
  }

  static Future<Res<bool>> test(Object? config, {WebDavProbe? probe}) async {
    final normalized = normalizeConfig(config);
    if (normalized == null) {
      return const Res.error('Invalid WebDAV configuration');
    }
    try {
      await (probe ?? _defaultProbe)(normalized);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<void> _defaultProbe(List<String> config) async {
    final client = newClient(
      config[0],
      user: config[1],
      password: config[2],
      adapter: RHttpAdapter(
        enableProxy: appdata.settings['webdavProxyEnabled'] != false,
      ),
    );
    await client.readDir('/');
  }
}

/// Facade over [SyncV2Service] that keeps the UI/headless call sites stable.
class DataSync with ChangeNotifier {
  DataSync._({bool initialize = true}) {
    if (!initialize) return;
    SyncV2Service.instance.addListener(_onServiceChanged);
    if (isEnabled) {
      unawaited(_autoInitialSync());
    }
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        if (!App.rootContext.mounted) return;
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  @visibleForTesting
  DataSync.forTesting() : this._(initialize: false);

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isUploading = false;
  bool _isDownloading = false;
  String? _lastError;

  bool get isUploading => _isUploading || SyncV2Service.instance.isUploading;

  bool get isDownloading =>
      _isDownloading || SyncV2Service.instance.isDownloading;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig({bool allowEmpty = true}) =>
      WebDavConnectionTester.normalizeConfig(
        appdata.settings['webdav'],
        allowEmpty: allowEmpty,
      );

  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isEnabled: isEnabled,
    isUploading: isUploading,
    isDownloading: isDownloading,
    lastSyncTime: (appdata.settings['lastSyncTime'] as int?) ?? 0,
    lastError: _lastError ?? SyncV2Service.instance.lastError,
  );

  Future<void> _autoInitialSync() async {
    try {
      await SyncV2Service.instance.init();
      final result = await SyncV2Service.instance.pullNow();
      _applyResult(result);
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      _lastError = error.toString();
      notifyListeners();
    }
  }

  void _applyResult(Res<bool> result) {
    _lastError = result.error ? result.errorMessage : null;
    notifyListeners();
  }

  void _onServiceChanged() {
    final serviceError = SyncV2Service.instance.lastError;
    if (serviceError != null) _lastError = serviceError;
    notifyListeners();
  }

  Future<Res<bool>> testConnection([Object? config]) {
    return WebDavConnectionTester.test(config ?? appdata.settings['webdav']);
  }

  Future<Res<bool>> uploadData() {
    if (!isEnabled) return Future.value(const Res(true));
    return uploadDataManually();
  }

  Future<Res<bool>> uploadDataManually() async {
    final config = _validateConfig();
    if (config == null) {
      return _fail('Invalid WebDAV configuration');
    }
    if (config.isEmpty) return const Res(true);
    await SyncV2Service.instance.ensureConfig();
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      final result = await SyncV2Service.instance.pushNow();
      _applyResult(result);
      return result;
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      return _fail(error.toString());
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() {
    if (!isEnabled) return Future.value(const Res(true));
    return downloadDataManually();
  }

  Future<Res<bool>> downloadDataManually() async {
    final config = _validateConfig();
    if (config == null) {
      return _fail('Invalid WebDAV configuration');
    }
    if (config.isEmpty) return const Res(true);
    await SyncV2Service.instance.ensureConfig();
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      final result = await SyncV2Service.instance.pullNow();
      _applyResult(result);
      return result;
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      return _fail(error.toString());
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Res<bool> _fail(String message) {
    _lastError = message;
    notifyListeners();
    return Res.error(message);
  }

  /// Called after the "sync login state" toggle changes.
  static Future<void> setAuthSyncEnabled(bool enabled) async {
    appdata.implicitData['syncAuthEnabled'] = enabled;
    await appdata.writeImplicitData();
    if (SyncV2Service.instance.isInitialized) {
      await SyncV2Service.instance.reconfigure();
      if (enabled) {
        await SyncV2Service.instance.rebuildAuthDomain();
      }
    }
  }

  /// Diagnostics for the settings page (plain maps keep the UI decoupled from
  /// the service types).
  static Future<Map<String, Object?>> syncDiagnostics() async {
    try {
      final diagnostics = await SyncV2Service.instance.diagnostics();
      return {
        'configured': diagnostics.configured,
        'deviceId': diagnostics.deviceId,
        'enabledDomains': diagnostics.enabledDomains,
        'pendingOps': diagnostics.pendingOps,
        'lastPush': diagnostics.lastPush,
        'applied': diagnostics.applied,
        'lastSnapshot': diagnostics.lastSnapshot == null
            ? null
            : {
                'device': diagnostics.lastSnapshot!.deviceId,
                'hlc': diagnostics.lastSnapshot!.hlc.encoded,
                'range': [
                  diagnostics.lastSnapshot!.rangeLo,
                  diagnostics.lastSnapshot!.rangeHi,
                ],
                'applied': diagnostics.lastSnapshot!.applied,
                'domains': diagnostics.lastSnapshot!.domains.toList()..sort(),
              },
        'lastError': diagnostics.lastError,
        'lastSyncTime': diagnostics.lastSyncTime,
        'recentConflicts': diagnostics.conflicts,
      };
    } catch (error) {
      return {'error': error.toString()};
    }
  }

  static Future<List<Map<String, Object?>>> syncDevices() async {
    try {
      return await SyncV2Service.instance.listRemoteDevices();
    } catch (error) {
      return [
        {'error': error.toString()},
      ];
    }
  }

  static Future<Res<bool>> removeSyncDevice(String deviceId) {
    return SyncV2Service.instance.removeRemoteDevice(deviceId);
  }

  /// Compatibility hook for callers that used to notify DataSync directly.
  void onDataChanged() {
    if (!isEnabled) return;
    SyncV2Service.instance.pushNow();
  }

  bool _handleWindowClose() {
    if (isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (isUploading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  @override
  void dispose() {
    SyncV2Service.instance.removeListener(_onServiceChanged);
    super.dispose();
  }
}
