/// App-level orchestration of the v2 WebDAV sync protocol (M1).
///
/// Responsibilities:
///  * own the [SqliteSyncStore], [WebDavSyncTransport] and [SyncEngine];
///  * project business SQLite databases into the store via adapters
///    (diff-based reconciliation, so manager write paths stay untouched);
///  * project merged remote state back into the business databases and reload
///    manager caches;
///  * cold-start migration/seed of the local device;
///  * debounce/auto push, manual pull/push, status/error reporting.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/sync/app/adapters/auth_adapter.dart';
import 'package:venera/sync/app/adapters/comic_setting_adapter.dart';
import 'package:venera/sync/app/adapters/comic_source_adapter.dart';
import 'package:venera/sync/app/adapters/favorites_adapter.dart';
import 'package:venera/sync/app/adapters/history_adapter.dart';
import 'package:venera/sync/app/adapters/image_favorite_adapter.dart';
import 'package:venera/sync/app/adapters/read_later_adapter.dart';
import 'package:venera/sync/app/adapters/settings_adapter.dart';
import 'package:venera/sync/app/sync_app_adapter.dart';
import 'package:venera/sync/app/sync_app_reconciler.dart';
import 'package:venera/sync/blob_sync.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/engine.dart';
import 'package:venera/sync/hlc.dart';
import 'package:venera/sync/snapshot.dart';
import 'package:venera/sync/sqlite_store.dart';
import 'package:venera/sync/transport.dart';
import 'package:venera/sync/webdav_transport.dart';
import 'package:venera/utils/io.dart';

class SyncV2Diagnostics {
  const SyncV2Diagnostics({
    this.configured = false,
    this.deviceId = '',
    this.enabledDomains = const [],
    this.pendingOps = 0,
    this.lastPush = 0,
    this.applied = const {},
    this.lastSnapshot,
    this.lastError,
    this.lastSyncTime = 0,
    this.conflicts = const [],
  });

  final bool configured;
  final String deviceId;
  final List<String> enabledDomains;
  final int pendingOps;
  final int lastPush;
  final Map<String, int> applied;
  final SnapshotInfo? lastSnapshot;
  final String? lastError;
  final int lastSyncTime;
  final List<Map<String, Object?>> conflicts;
}

class SyncV2Service extends ChangeNotifier {
  SyncV2Service._();

  static final SyncV2Service instance = SyncV2Service._();

  static const String syncV2DbFileName = 'sync_v2.db';

  /// Domains integrated in this build (M1 + M3 adapters).
  static const Set<String> _syncedDomains = {
    SyncDomains.history,
    SyncDomains.favoriteFolder,
    SyncDomains.favoriteComic,
    SyncDomains.favoriteOrder,
    SyncDomains.favoriteLink,
    SyncDomains.readLater,
    SyncDomains.setting,
    SyncDomains.imageFavorite,
    SyncDomains.comicSetting,
    SyncDomains.comicSource,
  };

  /// Domains whose business table can be emptied as a whole; the reconciler
  /// translates an empty projection into one clear-cutoff op instead of many
  /// deletes.
  static const Set<String> _clearableDomains = {
    SyncDomains.history,
    SyncDomains.readLater,
  };

  SqliteSyncStore? _store;
  WebDavSyncTransport? _transport;
  SyncEngine? _engine;
  SyncAppReconciler? _reconciler;
  final List<SyncAppAdapter> _adapters = [];

  Future<void>? _initFuture;
  String? _configSignature;
  bool _initialized = false;
  bool _disposed = false;
  bool _isUploading = false;
  bool _isDownloading = false;
  String? _lastError;
  int _historyRevision = 0;
  Timer? _debounce;
  Timer? _pollTimer;
  AppLifecycleListener? _lifecycle;
  Future<void>? _operation;

  bool get isInitialized => _initialized;

  bool get isUploading => _isUploading;

  bool get isDownloading => _isDownloading;

  String? get lastError => _lastError;

  /// Increments when a pull applied remote history data; the reader uses it to
  /// show a lightweight "another device read further" hint.
  int get historyRevision => _historyRevision;

  SqliteSyncStore? get store => _store;

  SyncEngine? get engine => _engine;

  /// True when a WebDAV configuration is present.
  bool get isConfigured => _normalizeConfig(allowEmpty: false) != null;

  bool get authSyncEnabled => SyncDomains.resolveAuthDomainEnabled(
    appdata.implicitData['syncAuthEnabled'],
  );

  bool get autoSyncEnabled => appdata.implicitData['webdavAutoSync'] == true;

  Set<String> get enabledDomains {
    final result = <String>{..._syncedDomains};
    if (authSyncEnabled) result.add(SyncDomains.auth);
    return result;
  }

  /// Reads the stored WebDAV config, validates it and returns `[url,user,pass]`
  /// (or an empty list when explicitly configured as empty / absent).
  List<String>? _normalizeConfig({bool allowEmpty = true}) {
    final raw = appdata.settings['webdav'];
    if (raw is! List) return null;
    if (raw.isEmpty) return allowEmpty ? const [] : null;
    if (raw.length != 3 || raw.whereType<String>().length != 3) return null;
    final values = raw.cast<String>().map((value) => value.trim()).toList();
    if (values[0].isEmpty) return null;
    return values;
  }

  String _resolveDeviceId() {
    final raw = appdata.settings['deviceId'];
    if (raw is String && hlcDeviceIdRegExp.hasMatch(raw.trim())) {
      return raw.trim();
    }
    // Deterministic fallback for broken/legacy settings; still fits the HLC
    // device-id grammar.
    final seed = (raw is String && raw.isNotEmpty) ? raw : App.dataPath;
    final hex = seed.codeUnits
        .fold<int>(0x5eed, (value, unit) => (value * 31 + unit) & 0x7fffffff)
        .toRadixString(16)
        .padLeft(8, '0');
    return 'device-$hex';
  }

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initInternal();
    _initFuture = future;
    future.catchError((Object _) {
      _initFuture = null;
    });
    return future;
  }

  Future<void> _initInternal() async {
    if (_initialized || _disposed) return;
    final config = _normalizeConfig();
    if (config == null || config.isEmpty) {
      throw StateError('WebDAV is not configured');
    }

    _configSignature = _signatureOf(config);
    final store = await SqliteSyncStore.open(
      dbPath: FilePath.join(App.dataPath, syncV2DbFileName),
      deviceId: _resolveDeviceId(),
    );
    _store = store;

    final transport = WebDavSyncTransport.connect(
      baseUrl: config[0],
      user: config[1],
      password: config[2],
    );
    _transport = transport;

    final adapters = <SyncAppAdapter>[
      HistoryAdapter(
        dbPath: FilePath.join(App.dataPath, 'history.db'),
        reload: _reloadHistory,
      ),
      ReadLaterAdapter(
        dbPath: FilePath.join(App.dataPath, 'read_later.db'),
        reload: _reloadReadLater,
      ),
      FavoritesAdapter(
        dbPath: FilePath.join(App.dataPath, 'local_favorite.db'),
        reload: _reloadFavorites,
      ),
      SettingsAdapter(
        keys: () => (appdata.toJson()['settings'] as Map).keys
            .whereType<String>()
            .toSet(),
        get: (key) => appdata.settings[key],
        set: (key, value) => appdata.settings[key] = value,
        persist: () => appdata.saveData(false),
        reload: () async => App.forceRebuild(),
      ),
      ImageFavoriteAdapter(
        dbPath: FilePath.join(App.dataPath, 'history.db'),
        reload: _reloadHistory,
      ),
      ComicSettingAdapter(
        readComicSettings: () => _comicSettings,
        set: (comicKey, value) {
          (_comicSettingsMap())[comicKey] = value;
        },
        persist: () => appdata.saveData(false),
        reload: () async => App.forceRebuild(),
      ),
      ComicSourceAdapter(
        sourceDir: FilePath.join(App.dataPath, 'comic_source'),
        blobSync: BlobSync(transport: transport, localDeviceId: store.deviceId),
        reload: _reloadComicSources,
      ),
      if (authSyncEnabled)
        AuthAdapter(
          dbPath: FilePath.join(App.dataPath, 'cookie.db'),
          reload: _reloadCookieJar,
        ),
    ];
    _adapters
      ..clear()
      ..addAll(adapters);

    _reconciler = SyncAppReconciler(
      adapters: adapters,
      enabledDomains: enabledDomains,
      clearableDomains: _clearableDomains,
    );

    final engine = SyncEngine(
      store: store,
      transport: transport,
      enabledDomains: enabledDomains,
    );
    await engine.init();
    _engine = engine;

    try {
      await _seedIfNeeded(engine, store);
    } catch (error, stack) {
      Log.error('Sync v2', 'Seed failed', stack);
      _lastError = error.toString();
    }

    HistoryManager().addListener(_onManagerChanged);
    LocalFavoritesManager().addListener(_onManagerChanged);
    ReadLaterManager().addListener(_onManagerChanged);

    try {
      await engine.recoverPendingCompaction();
    } catch (error, stack) {
      Log.error('Sync v2', 'Compaction recovery failed', stack);
    }

    _lifecycle = AppLifecycleListener(
      onStateChange: _onAppLifecycleStateChanged,
      onDetach: _stopPolling,
    );
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        autoSyncEnabled) {
      _startPolling();
    }

    _initialized = true;
    notifyListeners();
  }

  Future<void> _seedIfNeeded(SyncEngine engine, SqliteSyncStore store) async {
    if (appdata.implicitData['syncV2Seeded'] == true) return;
    Log.info('Sync v2', 'Seeding v2 sync state from local data');
    // Project local data first so local state wins LWW against older remote
    // records (documented one-time migration trade-off).
    await _reconciler!.reconcileLocal(store);
    await _ensureBlobs();
    try {
      final pull = await engine.pull();
      if (pull.changed) await _reconciler!.applyRemote(_store!);
    } catch (error, stack) {
      Log.error('Sync v2', 'Seed pull failed', stack);
    }
    await _ensureBlobs();
    final push = await engine.push();
    if (push.error != null) {
      Log.error('Sync v2', 'Seed push failed: ${push.error}');
    } else {
      await engine.snapshot();
    }
    appdata.implicitData['syncV2Seeded'] = true;
    await appdata.writeImplicitData();
  }

  // ------------------------------------------------------------- transfers --

  String _signatureOf(List<String> config) => [
    config[0],
    config[1],
    config[2],
    '${appdata.settings['webdavProxyEnabled'] != false}',
  ].join('\u0000');

  /// Rebuilds the engine if the WebDAV URL/credentials/proxy setting changed
  /// while the service was already initialized (e.g. the settings page saved a
  /// new server). Must be called before a transfer.
  Future<void> ensureConfig() async {
    if (_disposed) return;
    final config = _normalizeConfig();
    if (config == null || config.isEmpty) return;
    if (!_initialized) return;
    if (_signatureOf(config) == _configSignature) return;
    await reconfigure();
  }

  Future<Res<bool>> pullNow() {
    return _serialized(_pullInternal);
  }

  Future<Res<bool>> pushNow() {
    return _serialized(_pushInternal);
  }

  Future<Res<bool>> syncNow() {
    return _serialized(() async {
      final pull = await _pullInternal();
      if (pull.error) return pull;
      return _pushInternal();
    });
  }

  Future<Res<bool>> _serialized(Future<Res<bool>> Function() action) {
    final previous = _operation;
    final completer = Completer<void>();
    _operation = completer.future;
    return () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      try {
        return await action();
      } finally {
        completer.complete();
        if (identical(_operation, completer.future)) {
          _operation = null;
        }
      }
    }();
  }

  Future<Res<bool>> _pullInternal() async {
    final store = _store;
    final engine = _engine;
    if (store == null || engine == null) {
      await init();
    }
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    var changedAnything = false;
    try {
      await _reconciler!.reconcileLocal(store!);
      final result = await engine!.pull();
      changedAnything = result.changed;
      if (result.changed) {
        await _reconciler!.applyRemote(_store!);
        if (enabledDomains.contains(SyncDomains.history)) {
          _historyRevision++;
        }
      }
      if (result.errors.isNotEmpty) {
        _lastError = result.errors.first.message;
        return Res.error(_lastError!);
      }
      if (changedAnything) {
        await _touchLastSyncTime();
      }
      return const Res(true);
    } catch (error, stack) {
      Log.error('Sync v2', 'Pull failed', stack);
      _lastError = error.toString();
      return Res.error(_lastError!);
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> _pushInternal() async {
    final store = _store;
    final engine = _engine;
    if (store == null || engine == null) {
      await init();
    }
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      await _reconciler!.reconcileLocal(store!);
      await _ensureBlobs();
      final result = await engine!.push();
      if (result.error != null) {
        _lastError = result.error.toString();
        return Res.error(_lastError!);
      }
      await engine.maybeSnapshot();
      await _touchLastSyncTime();
      return const Res(true);
    } catch (error, stack) {
      Log.error('Sync v2', 'Push failed', stack);
      _lastError = error.toString();
      return Res.error(_lastError!);
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<void> _touchLastSyncTime() async {
    appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
    await appdata.saveData(false);
    notifyListeners();
  }

  // ---------------------------------------------------------- reconcile/apply --

  // ---------------------------------------------------------- M3 helpers --

  Map<String, Object?> get _comicSettings {
    final raw = appdata.settings['comicSpecificSettings'];
    if (raw is! Map) return const <String, Object?>{};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  Map<dynamic, dynamic> _comicSettingsMap() {
    final raw = appdata.settings['comicSpecificSettings'];
    if (raw is Map) return raw;
    final map = <String, Object?>{};
    appdata.settings['comicSpecificSettings'] = map;
    return map;
  }

  Future<void> _ensureBlobs() async {
    for (final adapter in _adapters) {
      if (adapter is SyncBlobAdapter) {
        try {
          await (adapter as SyncBlobAdapter).ensureBlobsUploaded();
        } catch (error, stack) {
          Log.error('Sync v2', 'Blob upload failed', stack);
          _lastError = error.toString();
        }
      }
    }
  }

  // ------------------------------------------------------- diagnostics/devices --

  /// Human-readable diagnostics for the settings page.
  Future<SyncV2Diagnostics> diagnostics() async {
    if (!isConfigured) {
      return const SyncV2Diagnostics(configured: false);
    }
    if (!_initialized) await init();
    final store = _store!;
    return SyncV2Diagnostics(
      configured: true,
      deviceId: store.deviceId,
      enabledDomains: enabledDomains.toList()..sort(),
      pendingOps: await store.pendingCount(),
      lastPush: await store.getLastPush(),
      applied: await store.getApplied(),
      lastSnapshot: await store.getLastSnapshot(),
      lastError: _lastError,
      lastSyncTime: (appdata.settings['lastSyncTime'] as int?) ?? 0,
      conflicts: await store.getRecentConflicts(limit: 20),
    );
  }

  /// Remote devices known to the server (for device management).
  Future<List<Map<String, Object?>>> listRemoteDevices() async {
    if (!isConfigured) return const [];
    if (!_initialized) await init();
    final transport = _transport!;
    final self = _store?.deviceId;
    final result = <Map<String, Object?>>[];
    for (final device in await transport.listDevices()) {
      RemoteState? state;
      try {
        state = await transport.readState(device.deviceId);
      } catch (_) {}
      result.add({
        'deviceId': device.deviceId,
        'isSelf': device.deviceId == self,
        'lastChange': state?.lastChange ?? 0,
        'lastSeen': state?.lastSeen?.toIso8601String(),
        'applied': state?.applied ?? const <String, int>{},
        'hasSnapshot': state?.snapshot != null,
      });
    }
    result.sort(
      (a, b) => (a['deviceId'] as String).compareTo(b['deviceId'] as String),
    );
    return result;
  }

  Future<Res<bool>> removeRemoteDevice(String deviceId) async {
    if (!isConfigured) {
      return const Res.error('WebDAV is not configured');
    }
    if (!_initialized) await init();
    if (deviceId == _store?.deviceId) {
      return const Res.error('Cannot remove this device');
    }
    try {
      await _transport!.deleteDevice(deviceId);
      return const Res(true);
    } catch (error, stack) {
      Log.error('Sync v2', 'Remove device failed', stack);
      return Res.error(error.toString());
    }
  }

  /// Replays the auth domain from retained changes/snapshots (M2, §3.4), then
  /// merges local cookies and pushes. Called when "sync login state" is
  /// re-enabled.
  Future<void> rebuildAuthDomain() async {
    if (!_initialized || !authSyncEnabled) return;
    try {
      await _engine?.replayDomain(SyncDomains.auth);
      await _reconciler!.reconcileLocal(_store!);
      await _reconciler!.applyRemote(_store!);
      await _engine?.push();
    } catch (error, stack) {
      Log.error('Sync v2', 'Auth domain rebuild failed', stack);
      _lastError = error.toString();
    }
  }

  // -------------------------------------------------------------- lifecycle --

  void _onAppLifecycleStateChanged(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      if (autoSyncEnabled) {
        _startPolling();
        pullNow();
      }
    } else {
      _stopPolling();
    }
  }

  void _startPolling() {
    if (_pollTimer != null || _disposed) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_initialized || !autoSyncEnabled) return;
      if (_isDownloading || _isUploading) return;
      pullNow();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ------------------------------------------------------------- reloading --

  Future<void> _reloadHistory() async {
    HistoryManager().close();
    await HistoryManager().init();
    HistoryManager().notifyChanges();
    ImageFavoriteManager().notifyChanges();
  }

  Future<void> _reloadComicSources() async {
    await ComicSourceManager().reload();
  }

  Future<void> _reloadReadLater() async {
    ReadLaterManager().close();
    await ReadLaterManager().init();
    ReadLaterManager().notifyChanges();
  }

  Future<void> _reloadFavorites() async {
    LocalFavoritesManager().close();
    await LocalFavoritesManager().init();
    LocalFavoritesManager().notifyChanges();
  }

  Future<void> _reloadCookieJar() async {
    final path = FilePath.join(App.dataPath, 'cookie.db');
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = SingleInstanceCookieJar(path)..init();
  }

  // -------------------------------------------------------------- lifecycle --

  void _onManagerChanged() {
    if (_disposed || !_initialized || !autoSyncEnabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      pushNow();
    });
  }

  /// Rebuilds the engine/adapters, e.g. after the "sync login state" toggle
  /// changed. Auth domain records already in the store stay; disabling only
  /// stops future apply/emit for that domain.
  Future<void> reconfigure() async {
    if (!_initialized) return;
    await _shutdown();
    await init();
  }

  Future<void> _shutdown() async {
    _stopPolling();
    _lifecycle?.dispose();
    _lifecycle = null;
    _debounce?.cancel();
    _debounce = null;
    if (_initialized) {
      HistoryManager().removeListener(_onManagerChanged);
      LocalFavoritesManager().removeListener(_onManagerChanged);
      ReadLaterManager().removeListener(_onManagerChanged);
    }
    _initialized = false;
    _reconciler = null;
    final engine = _engine;
    _engine = null;
    final transport = _transport;
    _transport = null;
    final store = _store;
    _store = null;
    try {
      await engine?.close();
    } catch (_) {
      await transport?.close();
    }
    try {
      await store?.close();
    } catch (_) {}
    _initFuture = null;
  }

  Future<void> disposeService() async {
    _disposed = true;
    await _shutdown();
    super.dispose();
  }
}
