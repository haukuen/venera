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
import 'dart:convert';

import 'package:crypto/crypto.dart';
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
import 'package:venera/sync/app/adapters/comic_source_data_adapter.dart';
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
  BlobSync? _blobSync;
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
  Timer? _flushDebounce;
  Timer? _pollTimer;
  AppLifecycleListener? _lifecycle;
  Future<void>? _operation;

  /// Store meta key set before merged records are projected into the business
  /// databases and cleared afterwards.
  ///
  /// A pull advances the applied watermarks before `applyRemote` runs. If the
  /// app dies in between, the next pull would see "nothing new" and skip the
  /// projection forever. The marker makes that projection retryable; it also
  /// guarantees the projection happens *before* the next `reconcileLocal`, so
  /// business rows that were merged but never written back are not mistaken
  /// for local deletions and tombstoned.
  static const String _metaProjectionPending = 'projectionPending';

  /// Implicit-data key that forces one projection on the first start after
  /// upgrading from a build where snapshot-only pulls did not project their
  /// merged records.
  static const String _implicitProjectionSeeded = 'syncV2ProjectionSeeded';

  /// Store meta key prefix persisting the blob ledger: sha256 -> last-verified
  /// epoch ms. Backs [BlobSync] so already-uploaded blobs are never probed
  /// or re-downloaded on subsequent pushes. Suffixed per server account.
  static const String _metaBlobLedgerPrefix = 'blobLedger.';

  /// Per-account ledger meta key. Purely derived from the WebDAV config so
  /// switching servers can never inherit the previous account's "uploaded"
  /// claims. Not release-compatible sensitive: the ledger shipped nowhere yet.
  static String blobLedgerMetaKey(String url, String user, String password) {
    final digest = sha256.convert(utf8.encode('$url\n$user\n$password'));
    return '$_metaBlobLedgerPrefix${digest.toString().substring(0, 16)}';
  }

  static String _blobLedgerMetaKey(List<String> config) =>
      blobLedgerMetaKey(config[0], config[1], config[2]);

  /// Store meta key holding the epoch ms of the last blob GC run.
  static const String _metaBlobGcAt = 'blobGcAt';

  /// Minimum interval between blob GC sweeps that had no new uploads.
  static const Duration _blobGcInterval = Duration(hours: 1);

  /// Upper bound for open-path pulls ([pullNowFast]): the reader and comic
  /// details wait this long for fresh cross-device progress before opening
  /// with the local state.
  static const Duration quickPullTimeout = Duration(seconds: 2);

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

  String get _comicSourceDir => FilePath.join(App.dataPath, 'comic_source');

  String _resolveDeviceId() {
    final raw = appdata.settings['deviceId'];
    final seed = (raw is String && raw.isNotEmpty) ? raw : App.dataPath;
    return resolveSyncDeviceId(raw, seed);
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

    // The ledger is scoped to the server account: a ledger hit claims "this
    // blob is present on the remote", which is meaningless after switching
    // URL/credentials. Keying the meta by a hash of the config makes every
    // account start from an empty ledger automatically — no reconfigure hook
    // and no stale claims about a server we no longer talk to.
    final blobLedgerKey = _blobLedgerMetaKey(config);
    final blobSync = BlobSync(
      transport: transport,
      localDeviceId: store.deviceId,
      ledgerLoader: () async {
        final raw = await store.getMeta(blobLedgerKey);
        if (raw == null || raw.isEmpty) return null;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) return null;
          return decoded.map<String, int>(
            (key, value) => MapEntry(key.toString(), (value as num).toInt()),
          );
        } catch (_) {
          return null;
        }
      },
      ledgerSaver: (ledger) => store.setMeta(blobLedgerKey, jsonEncode(ledger)),
    );
    _blobSync = blobSync;
    final adapters = <SyncAppAdapter>[
      HistoryAdapter(
        dbPath: FilePath.join(App.dataPath, 'history.db'),
        reload: _reloadHistory,
        onWarning: _logAdapterWarning,
      ),
      ReadLaterAdapter(
        dbPath: FilePath.join(App.dataPath, 'read_later.db'),
        reload: _reloadReadLater,
        onWarning: _logAdapterWarning,
      ),
      FavoritesAdapter(
        dbPath: FilePath.join(App.dataPath, 'local_favorite.db'),
        reload: _reloadFavorites,
        onWarning: _logAdapterWarning,
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
        onWarning: _logAdapterWarning,
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
        sourceDir: _comicSourceDir,
        blobSync: blobSync,
        reload: _reloadComicSources,
      ),
      // Source login tokens live in `<key>.data` sidecars, not in the JS
      // definition, so they need their own projection. They share the `auth`
      // domain (and therefore the "sync login state" toggle).
      if (authSyncEnabled)
        ComicSourceDataAdapter(
          sourceDir: _comicSourceDir,
          blobSync: blobSync,
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
      onWarning: _logAdapterWarning,
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

    // Recover merged-but-unprojected records before any reconciliation can
    // mistake them for local deletions. The one-time flag also repairs data
    // merged by older builds that skipped projection after a snapshot repair.
    try {
      if (appdata.implicitData[_implicitProjectionSeeded] != true) {
        appdata.implicitData[_implicitProjectionSeeded] = true;
        await appdata.writeImplicitData();
        await store.setMeta(_metaProjectionPending, '1');
      }
      await _projectPendingIfNeeded(store);
    } catch (error, stack) {
      Log.error('Sync v2', 'Pending projection failed', stack);
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
    // records (documented one-time migration trade-off). The returned
    // retention domains are ignored deliberately: with an empty store no
    // deletion can be emitted (there is nothing to diff against), and
    // re-projecting an empty store is a no-op.
    await _reconciler!.reconcileLocal(store);
    final blobFailures = await _ensureBlobs();
    if (blobFailures > 0) {
      Log.error(
        'Sync v2',
        'Seed aborted: $blobFailures blob upload(s) failed; '
            'retrying on the next sync',
      );
      // Deliberately not marking the seed as done: the next start retries.
      return;
    }
    try {
      final pull = await engine.pull();
      if (pull.changed) await _projectRemote(store);
    } catch (error, stack) {
      Log.error('Sync v2', 'Seed pull failed', stack);
    }
    final push = await engine.push();
    if (push.error != null) {
      Log.error('Sync v2', 'Seed push failed: ${push.error}');
    } else {
      await engine.snapshot();
    }
    appdata.implicitData['syncV2Seeded'] = true;
    await appdata.writeImplicitData();
  }

  /// Projects the merged store into the business databases with a crash-safe
  /// marker: the marker survives a failure between watermark advance and
  /// projection, so [_projectPendingIfNeeded] retries instead of treating the
  /// pull as "nothing new".
  Future<void> _projectRemote(SqliteSyncStore store) async {
    await store.setMeta(_metaProjectionPending, '1');
    await _reconciler!.applyRemote(store);
    await store.setMeta(_metaProjectionPending, null);
  }

  Future<void> _projectPendingIfNeeded(SqliteSyncStore store) async {
    if (await store.getMeta(_metaProjectionPending) == null) return;
    await _projectRemote(store);
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

  /// Pull that gives up after [quickPullTimeout] instead of stalling open
  /// paths (reader, comic details). The underlying pull keeps running in the
  /// operation queue; a pull that applies remote history notifies the reader
  /// through [historyRevision].
  Future<bool> pullNowFast() async {
    try {
      final result = await pullNow().timeout(quickPullTimeout);
      return result.success;
    } catch (_) {
      return false;
    }
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
    var store = _store;
    var engine = _engine;
    if (store == null || engine == null) {
      await init();
      store = _store;
      engine = _engine;
    }
    final syncStore = store!;
    final syncEngine = engine!;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    var changedAnything = false;
    try {
      // Project anything a previous pull merged but never wrote back before
      // reconciliation can classify those records as local deletions.
      await _projectPendingIfNeeded(syncStore);
      // Reconcile BEFORE pulling, unconditionally. Both directions of the
      // race need it:
      //  * deletions: a pull must not project the still-alive store record
      //    back over a row the user just deleted (resurrection + suppressed
      //    tombstone);
      //  * insertions: the incoming projection must not delete local rows
      //    that have not been emitted into the store yet (a fresh cookie or
      //    favorite folder would be wiped by any remote change).
      // This is local SQLite work only; the expensive parts of a pull are on
      // the network and untouched by this scan.
      final retained = await _reconciler!.reconcileLocal(syncStore);
      if (retained.isNotEmpty) {
        // The local business data was recreated or unreadable: restore it
        // from the merged store now instead of waiting for the next remote
        // change. This also re-aligns the business database identity tokens.
        await _projectRemote(syncStore);
      }
      final result = await syncEngine.pull();
      changedAnything = result.changed;
      if (result.changed) {
        await _projectRemote(syncStore);
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
    var store = _store;
    var engine = _engine;
    if (store == null || engine == null) {
      await init();
      store = _store;
      engine = _engine;
    }
    final syncStore = store!;
    final syncEngine = engine!;
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      await _projectPendingIfNeeded(syncStore);
      final retained = await _reconciler!.reconcileLocal(syncStore);
      if (retained.isNotEmpty) {
        // See _pullInternal: re-project recreated/unreadable business data
        // before pushing, so the next reconciliation sees restored rows.
        await _projectRemote(syncStore);
      }
      // Amortized ledger re-verification: a couple of range probes per push
      // keep the ledger honest, so blobs pruned manually on the server are
      // re-uploaded within minutes instead of silently assumed present.
      final blobSyncForReverify = _blobSync;
      if (blobSyncForReverify != null) {
        try {
          await blobSyncForReverify.reverifyOldest(
            blobSyncForReverify.ledgerReverifyCount,
          );
        } catch (error, stack) {
          Log.error('Sync v2', 'Blob ledger reverify failed', stack);
        }
      }
      final blobFailures = await _ensureBlobs();
      if (blobFailures > 0) {
        // The outbox keeps its ops; the next push retries both the blob and
        // the change files, so nothing is lost by aborting here.
        _lastError = '$blobFailures blob upload(s) failed; push aborted';
        return Res.error(_lastError!);
      }
      final result = await syncEngine.push();
      if (result.error != null) {
        _lastError = result.error.toString();
        return Res.error(_lastError!);
      }
      await syncEngine.maybeSnapshot();
      await _gcBlobs();
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

  /// Uploads every referenced blob. Returns the number of failed uploads;
  /// callers must abort the push when it is non-zero, otherwise the record
  /// would reference a blob that no later sync re-uploads.
  Future<int> _ensureBlobs() async {
    var failed = 0;
    for (final adapter in _adapters) {
      if (adapter is! SyncBlobAdapter) continue;
      try {
        failed += await (adapter as SyncBlobAdapter).ensureBlobsUploaded();
      } catch (error, stack) {
        Log.error('Sync v2', 'Blob upload failed', stack);
        _lastError = error.toString();
        failed++;
      }
    }
    return failed;
  }

  /// Deletes blobs on this device's branch that no *visible* record of the
  /// local store references anymore.
  ///
  /// Throttled: the sweep costs a full store dump plus a remote blob listing,
  /// so it runs right after a push that uploaded blobs, and otherwise at most
  /// once per [_blobGcInterval].
  ///
  /// Safe only after a successful push + snapshot: the snapshot carries the
  /// surviving references, and content-addressed names make a re-upload of
  /// still-needed content a no-op even if a concurrent device still holds an
  /// older reference. Tombstones count as no reference (the blob is dead
  /// content), but a record whose tombstone is *older* than its value may
  /// still be referenced — `visible` decides, matching what peers can request.
  Future<void> _gcBlobs() async {
    final blobSync = _blobSync;
    final store = _store;
    if (blobSync == null || store == null) return;
    final uploadedSomething = blobSync.uploadsSinceLastGc > 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!uploadedSomething) {
      final lastGc =
          int.tryParse(await store.getMeta(_metaBlobGcAt) ?? '') ?? 0;
      if (nowMs - lastGc < _blobGcInterval.inMilliseconds) return;
    }
    try {
      final referenced = <String>{};
      for (final record in await store.dumpRecords()) {
        if (!record.visible) continue;
        final sha256 = record.data?['sha256'];
        if (sha256 is String) referenced.add(sha256);
      }
      final deleted = await blobSync.deleteUnreferenced(referenced);
      if (deleted > 0) {
        Log.info('Sync v2', 'Blob GC removed $deleted unreferenced blob(s)');
      }
      await store.setMeta(_metaBlobGcAt, '$nowMs');
      blobSync.resetUploadCounter();
    } catch (error, stack) {
      // Garbage collection must never fail the push.
      Log.error('Sync v2', 'Blob GC failed', stack);
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

  /// Replays the auth domain (cookies + comic source login state) from
  /// retained changes/snapshots (M2, §3.4), projects the merged state, then
  /// merges local state and pushes. Called when "sync login state" is
  /// re-enabled.
  Future<void> rebuildAuthDomain() async {
    if (!_initialized || !authSyncEnabled) return;
    final store = _store;
    if (store == null) return;
    try {
      // Capture login changes made while the domain was disabled first: they
      // become fresh versions, so the replay cannot overwrite them. Projecting
      // before reconciling would instead delete those local-only changes.
      await _reconciler!.reconcileLocal(store);
      await _engine?.replayDomain(SyncDomains.auth);
      await _projectRemote(store);
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
      // Leaving the foreground (or losing focus on desktop): push whatever
      // the debounce is still holding before the OS suspends us.
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        _flushPendingPush();
      }
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

  /// Adapter warnings (unreadable business data, skipped rows) are important
  /// operational signals; surface them in the log page.
  void _logAdapterWarning(String message) => Log.warning('Sync v2', message);

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

  /// Push debounce: every local change restarts the timer, so a burst of
  /// edits becomes one push. 15s (not 3s) for two reasons:
  ///  * every push is a full HTTP round trip on a short-connection WebDAV —
  ///    steady reading used to produce one push (and one 1-op change file)
  ///    per ~3s page turn;
  ///  * the store coalesces same-key pending ops in place, but only while
  ///    they are unfrozen — a longer window lets page turns of the same comic
  ///    collapse into a single op before the first one is delivered.
  /// Matches Chrome Sync's Sessions nudge (15s), the largest of its type
  /// delays for exactly this class of high-frequency overwrite writes.
  static const Duration _pushDebounce = Duration(seconds: 15);

  /// Max-latency cap (Syncthing's 10s→60s rule): the debounce above is
  /// restarted by every change, so continuous reading would postpone the
  /// push indefinitely. Whatever happens, pending local changes leave this
  /// device within 60s.
  static const Duration _pushMaxLatency = Duration(seconds: 60);

  void _onManagerChanged() {
    if (_disposed || !_initialized || !autoSyncEnabled) return;
    _debounce?.cancel();
    _debounce = Timer(_pushDebounce, () {
      _debounce = null;
      _flushDebounce?.cancel();
      _flushDebounce = null;
      _autoPush();
    });
    // The cap timer is NOT restarted by later changes: it measures since the
    // first unsent change of the current burst. Clearing itself when it fires
    // is what allows `??=` to arm a fresh cap for the next burst — without
    // it, the cap would protect exactly one burst per app session.
    _flushDebounce ??= Timer(_pushMaxLatency, () {
      _flushDebounce = null;
      _debounce?.cancel();
      _debounce = null;
      _autoPush();
    });
  }

  /// Fires a debounced auto-push, re-checking the setting at fire time: the
  /// user can turn auto sync off while a timer is still armed, and an armed
  /// timer must never push against the now-disabled setting.
  void _autoPush() {
    if (_disposed || !_initialized || !autoSyncEnabled) return;
    pushNow();
  }

  /// Cancels the pending auto-push timers without touching the outbox.
  ///
  /// Called when the user turns auto sync off: local changes stay pending and
  /// are delivered by the next explicit push, or automatically once auto sync
  /// is enabled again and the next change arms a fresh timer.
  void cancelPendingAutoPush() {
    _debounce?.cancel();
    _debounce = null;
    _flushDebounce?.cancel();
    _flushDebounce = null;
  }

  /// Pushes immediately when the app leaves the foreground. Event-boundary
  /// flush is the industry default (Chrome/CKSyncEngine commit on lifecycle
  /// events): the 15s debounce must not hold changes hostage while the app
  /// sits in the background with the OS about to suspend it.
  void _flushPendingPush() {
    if (_disposed || !autoSyncEnabled) return;
    final debounce = _debounce;
    // Nothing pending: `isActive` would throw on a null timer.
    if (debounce == null || !debounce.isActive) return;
    cancelPendingAutoPush();
    pushNow();
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
    _flushDebounce?.cancel();
    _flushDebounce = null;
    if (_initialized) {
      HistoryManager().removeListener(_onManagerChanged);
      LocalFavoritesManager().removeListener(_onManagerChanged);
      ReadLaterManager().removeListener(_onManagerChanged);
    }
    _initialized = false;
    _reconciler = null;
    for (final adapter in _adapters) {
      if (adapter is! SyncDisposableAdapter) continue;
      try {
        (adapter as SyncDisposableAdapter).dispose();
      } catch (_) {}
    }
    _adapters.clear();
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
