import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      downloadData();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    _uploadDebounce?.cancel();
    if (!isEnabled) return;
    _uploadDebounce = Timer(const Duration(seconds: 5), () {
      if (!isEnabled) return;
      uploadData();
    });
  }

  bool _handleWindowClose() {
    if (_isUploading) {
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
    while (_isUploading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  Completer<void>? _syncLock;
  Timer? _uploadDebounce;

  Future<void> _acquireLock() async {
    while (_syncLock != null) {
      await _syncLock!.future;
    }
    _syncLock = Completer<void>();
  }

  void _releaseLock() {
    var lock = _syncLock;
    _syncLock = null;
    lock?.complete();
  }

  @override
  void dispose() {
    _uploadDebounce?.cancel();
    super.dispose();
  }

  static const _backupFiles = [
    'history.db',
    'local_favorite.db',
    'read_later.db',
    'cookie.db',
    'appdata.json',
  ];

  String get _backupDir => FilePath.join(App.cachePath, 'sync_backup');

  Future<void> _backupLocalData() async {
    var backupDir = Directory(_backupDir);
    if (backupDir.existsSync()) {
      backupDir.deleteSync(recursive: true);
    }
    backupDir.createSync();

    for (var name in _backupFiles) {
      var src = File(FilePath.join(App.dataPath, name));
      if (src.existsSync()) {
        src.copySync(FilePath.join(_backupDir, name));
      }
    }

    var srcDir = Directory(FilePath.join(App.dataPath, 'comic_source'));
    var dstDir = Directory(FilePath.join(_backupDir, 'comic_source'));
    if (srcDir.existsSync()) {
      dstDir.createSync();
      for (var f in srcDir.listSync()) {
        if (f is File) {
          f.copySync(FilePath.join(_backupDir, 'comic_source', f.name));
        }
      }
    }
  }

  Future<void> _restoreBackup() async {
    var backupDir = Directory(_backupDir);
    if (!backupDir.existsSync()) return;

    // 先关闭所有数据库连接，避免 Windows 文件锁
    HistoryManager().close();
    LocalFavoritesManager().close();
    ReadLaterManager().close();
    SingleInstanceCookieJar.instance?.dispose();

    for (var name in _backupFiles) {
      var src = File(FilePath.join(_backupDir, name));
      if (src.existsSync()) {
        var dst = File(FilePath.join(App.dataPath, name));
        if (dst.existsSync()) {
          dst.renameSync(FilePath.join(App.dataPath, '$name.bak'));
        }
        // Clean WAL companion files from older versions
        if (name.endsWith('.db')) {
          for (final suffix in const ['-wal', '-shm']) {
            final f = File(FilePath.join(App.dataPath, '$name$suffix'));
            if (f.existsSync()) {
              try {
                f.deleteSync();
              } catch (_) {}
            }
          }
        }
        src.copySync(dst.path);
        File(FilePath.join(App.dataPath, '$name.bak')).deleteIgnoreError();
      }
    }

    var srcDir = Directory(FilePath.join(_backupDir, 'comic_source'));
    if (srcDir.existsSync()) {
      var dstDir = Directory(FilePath.join(App.dataPath, 'comic_source'));
      dstDir.deleteIfExistsSync(recursive: true);
      dstDir.createSync();
      for (var f in srcDir.listSync()) {
        if (f is File) {
          f.copySync(FilePath.join(App.dataPath, 'comic_source', f.name));
        }
      }
    }

    await HistoryManager().init();
    await LocalFavoritesManager().init();
    await ReadLaterManager().init();
    SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
      FilePath.join(App.dataPath, "cookie.db"),
    )..init();

    // Reload in-memory appdata from the restored appdata.json
    var restoredAppdata = File(FilePath.join(App.dataPath, 'appdata.json'));
    if (restoredAppdata.existsSync()) {
      try {
        var json = jsonDecode(await restoredAppdata.readAsString());
        appdata.syncData(json);
      } catch (e) {
        Log.error("Data Sync", "Failed to reload appdata after restore: $e");
      }
    }

    // 确保所有监听者收到通知
    HistoryManager().notifyChanges();
    LocalFavoritesManager().notifyChanges();
    ReadLaterManager().notifyChanges();
  }

  void _cleanupBackup() {
    var backupDir = Directory(_backupDir);
    if (backupDir.existsSync()) {
      backupDir.deleteSync(recursive: true);
    }
  }

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData() async {
    if (_isDownloading) return const Res(true);
    await _acquireLock();
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(
          enableProxy: appdata.settings['webdavProxyEnabled'] != false,
        ),
      );

      try {
        var disableFields = appdata.settings['disableSyncFields'];
        var data = await exportAppData(
          disableFields != null && disableFields.toString().isNotEmpty,
        );
        var now = DateTime.now().millisecondsSinceEpoch;
        var filename = '$now.venera';
        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();

        // Remove file with same timestamp prefix (extremely unlikely but safe)
        var existing = files.firstWhereOrNull((e) => e.name == filename);
        if (existing != null) {
          await client.remove(existing.name!);
        }

        await client.write(filename, await data.readAsBytes());
        data.deleteIgnoreError();

        // Update lastSyncTime
        appdata.settings['lastSyncTime'] = now;
        await appdata.saveData(false);

        // Sort numerically and remove oldest if over 10 files
        files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        files.sort((a, b) {
          var ta = int.tryParse(a.name!.replaceAll('.venera', '')) ?? 0;
          var tb = int.tryParse(b.name!.replaceAll('.venera', '')) ?? 0;
          return ta.compareTo(tb);
        });
        while (files.length > 10) {
          await client.remove(files.first.name!);
          files.removeAt(0);
        }

        // Clean up old format files ({days}-{version}.venera)
        for (var f in files) {
          if (f.name!.contains('-') &&
              !f.name!.startsWith('${now ~/ 86400000}-')) {
            var part = f.name!.replaceAll('.venera', '');
            var parts = part.split('-');
            if (parts.length == 2 &&
                int.tryParse(parts[0]) != null &&
                int.tryParse(parts[1]) != null) {
              await client.remove(f.name!);
            }
          }
        }

        Log.info("Upload Data", "Data uploaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      }
    } finally {
      _isUploading = false;
      _releaseLock();
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
    if (_isUploading) return const Res(true);
    await _acquireLock();
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(
          enableProxy: appdata.settings['webdavProxyEnabled'] != false,
        ),
      );

      try {
        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        files.sort((a, b) {
          var ta = int.tryParse(a.name!.replaceAll('.venera', '')) ?? 0;
          var tb = int.tryParse(b.name!.replaceAll('.venera', '')) ?? 0;
          return tb.compareTo(ta); // newest first
        });

        if (files.isEmpty) {
          Log.info("Data Sync", 'No data file found on server');
          return const Res(true);
        }

        var remoteFile = files.first;
        var remoteTimestamp = int.tryParse(
          remoteFile.name!.replaceAll('.venera', ''),
        );
        var lastSyncTime = (appdata.settings['lastSyncTime'] as int?) ?? 0;

        // If remote file is old format ({days}-{version}.venera), always download
        // Old format files contain a dash, new format is pure timestamp
        var isOldFormat = remoteFile.name!.contains('-');

        if (!isOldFormat &&
            remoteTimestamp != null &&
            remoteTimestamp <= lastSyncTime) {
          Log.info("Data Sync", 'No new data to download');
          return const Res(true);
        }

        Log.info("Data Sync", "Downloading data from WebDAV server");
        var localFile = File(FilePath.join(App.cachePath, remoteFile.name!));
        await client.read2File(remoteFile.name!, localFile.path);

        await _backupLocalData();
        try {
          await importAppData(localFile, skipDataVersionCheck: true);
          await localFile.delete();

          // Update lastSyncTime from the downloaded file's timestamp
          if (remoteTimestamp != null) {
            appdata.settings['lastSyncTime'] = remoteTimestamp;
            await appdata.saveData(false);
          }

          _cleanupBackup();
          Log.info("Data Sync", "Data downloaded successfully");
          return const Res(true);
        } catch (e, s) {
          Log.error("Data Sync", "Import failed, restoring backup", s);
          await _restoreBackup();
          _cleanupBackup();
          _lastError = 'Download failed: $e';
          return Res.error(_lastError!);
        }
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      }
    } finally {
      _isDownloading = false;
      _releaseLock();
      notifyListeners();
    }
  }
}
