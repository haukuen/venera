/// App adapter for comic source login state (`<sourceKey>.data` sidecars).
///
/// Sources such as picacg, komga, ccc, copy_manga and jm persist their login
/// token (and other source-local state) with `ComicSource.saveData`, which
/// writes `<App.dataPath>/comic_source/<sourceKey>.data` (a JSON object). That
/// file is not part of the `comicSource` JavaScript domain, so without this
/// adapter a login performed on one device never reaches another device.
///
/// The records live in the `auth` domain because they *are* login state and
/// must follow the device-local "sync login state" toggle (§3.4):
///
///  * the domain is only enabled when the toggle is on, so a disabled device
///    neither uploads nor applies them;
///  * keys are `[@sourceData, sourceKey]` — two segments, while cookie keys
///    always have three — so both record kinds share the domain safely;
///  * the payload is only a blob reference; the bytes (and the sha256 check)
///    are handled by [BlobSync], exactly like `comicSource` JavaScript files.
///
/// The merge rule is LWW per source key (register semantics). This is a whole
/// file: two devices logging into the same source with different accounts
/// converge on the latest login.
///
/// This file is pure Dart (no Flutter imports) so it can be tested with temp
/// directories and the in-memory fake transport.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../blob_sync.dart';
import '../../domains.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

class ComicSourceDataAdapter implements SyncAppAdapter, SyncBlobAdapter {
  ComicSourceDataAdapter({
    required String sourceDir,
    required BlobSync blobSync,
    Future<void> Function()? reload,
    void Function(String message)? onWarning,
  }) : _sourceDir = sourceDir,
       _blobSync = blobSync,
       _reload = reload,
       _onWarning = onWarning;

  final String _sourceDir;
  final BlobSync _blobSync;
  final Future<void> Function()? _reload;
  final void Function(String message)? _onWarning;

  static const String dataExtension = '.data';

  static const Set<String> _domains = <String>{SyncDomains.auth};

  @override
  Set<String> get domains => _domains;

  Directory get _directory => Directory(_sourceDir);

  /// Projects every `<sourceKey>.data` file as one `auth` register.
  ///
  /// Invalid/empty JSON is skipped with a warning instead of syncing bytes the
  /// receiving source could not load. Does not touch the transport; blobs are
  /// uploaded later by [ensureBlobsUploaded].
  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final records = <AdapterRecord>[];
    for (final file in _dataFiles()) {
      final stem = _stemOf(file);
      if (stem == null) {
        _warn('source data: skipping unsafe file name ${file.path}');
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        if (!_isJsonObject(bytes)) {
          _warn('source data: skipping invalid JSON in ${file.path}');
          continue;
        }
        records.add(
          AdapterRecord(
            domain: SyncDomains.auth,
            key: SyncKeys.sourceDataKey(stem),
            field: '',
            kind: SyncOpKind.upsert,
            data: <String, Object?>{
              'sha256': BlobSync.sha256Hex(bytes),
              'size': bytes.length,
            },
          ),
        );
      } catch (error) {
        _warn('source data: failed to read ${file.path}: $error');
      }
    }
    return records;
  }

  /// Uploads every valid `.data` file to this device's blob branch. Returns
  /// the number of files that could not be uploaded (read failures only —
  /// invalid JSON is not a blob this adapter ever referenced).
  @override
  Future<int> ensureBlobsUploaded() async {
    var failed = 0;
    for (final file in _dataFiles()) {
      if (_stemOf(file) == null) continue;
      try {
        final bytes = await file.readAsBytes();
        if (!_isJsonObject(bytes)) continue;
        await _blobSync.upload(bytes);
      } catch (error) {
        failed++;
        _warn('source data: failed to upload ${file.path}: $error');
      }
    }
    return failed;
  }

  /// Writes visible source-data records back as `<sourceKey>.data` files and
  /// removes files whose record was tombstoned.
  ///
  /// Cookie records (three-part keys) are ignored: they belong to
  /// [AuthAdapter]. Files with no store record at all are left alone, so a
  /// freshly written local `.data` is never destroyed by a pull that happened
  /// before the next reconciliation.
  @override
  Future<void> applyRemote(SyncStore store) async {
    final stored = await store.dumpRecords(domains: _domains);
    final desired = <String, String>{};
    final tombstoned = <String>{};
    for (final record in stored) {
      if (record.field.isNotEmpty) continue;
      final parts = record.key.parts;
      if (!SyncKeys.isSourceDataKey(parts)) continue;
      final stem = parts[1];
      if (!_isSafeStem(stem)) {
        _warn('source data: ignoring unsafe key ${record.key.encode()}');
        continue;
      }
      if (!record.visible) {
        tombstoned.add(stem);
        continue;
      }
      final sha256 = record.data?['sha256'];
      if (sha256 is! String || !BlobSync.sha256Pattern.hasMatch(sha256)) {
        _warn('source data: ignoring record with invalid sha256 for "$stem"');
        continue;
      }
      desired[stem] = sha256;
    }

    var changed = 0;
    if (desired.isNotEmpty) {
      try {
        if (!await _directory.exists()) {
          await _directory.create(recursive: true);
        }
      } catch (error) {
        _warn('source data: cannot create ${_directory.path}: $error');
        return;
      }
    }
    for (final entry in desired.entries) {
      final target = _fileFor(entry.key);
      Uint8List? bytes;
      try {
        bytes = await _blobSync.downloadFromAnyDevice(entry.value);
      } catch (error) {
        _warn('source data: failed to download blob ${entry.value}: $error');
        continue;
      }
      if (bytes == null) {
        _warn(
          'source data: blob ${entry.value} for "${entry.key}" is missing or '
          'tampered; keeping the local file (if any)',
        );
        continue;
      }
      if (!_isJsonObject(bytes)) {
        _warn(
          'source data: blob ${entry.value} for "${entry.key}" is not a JSON '
          'object; keeping the local file (if any)',
        );
        continue;
      }
      try {
        if (await target.exists()) {
          final existing = await target.readAsBytes();
          if (BlobSync.sha256Hex(existing) == entry.value) continue;
        }
        await _writeAtomically(target, bytes);
        changed++;
      } catch (error) {
        _warn('source data: failed to write ${target.path}: $error');
      }
    }

    for (final stem in tombstoned) {
      final target = _fileFor(stem);
      try {
        if (!await target.exists()) continue;
        await target.delete();
        changed++;
      } catch (error) {
        _warn('source data: failed to delete ${target.path}: $error');
      }
    }

    if (changed > 0) await _reload?.call();
  }

  @override
  Future<void> reload() async {
    await _reload?.call();
  }

  /// Login sidecars are retained while they are merely unreadable.
  ///
  /// `readLocalRecords` skips invalid JSON with a warning; without this hook
  /// the reconciler would tombstone the record and delete the login state on
  /// every other device. A real logout rewrites the file (still valid JSON) or
  /// removes the record through [applyRemote]'s tombstone handling, so genuine
  /// deletions still propagate.
  @override
  bool retainsMissingRecord(StoredRecord record) {
    if (record.domain != SyncDomains.auth) return false;
    return SyncKeys.isSourceDataKey(record.key.parts);
  }

  /// Local `*.data` files, sorted for deterministic projections.
  List<File> _dataFiles() {
    final directory = _directory;
    if (!directory.existsSync()) return const <File>[];
    final files = <File>[];
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith(dataExtension)) continue;
        files.add(entity);
      }
    } catch (error) {
      _warn('source data: failed to list ${directory.path}: $error');
      return const <File>[];
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Source key of [file] (`<stem>.data`), or `null` when the name is unsafe.
  String? _stemOf(File file) {
    final name = _fileName(file);
    if (!name.endsWith(dataExtension)) return null;
    final stem = name.substring(0, name.length - dataExtension.length);
    return _isSafeStem(stem) ? stem : null;
  }

  File _fileFor(String stem) =>
      File('${_directory.path}${Platform.pathSeparator}$stem$dataExtension');

  /// Writes a sidecar through a temporary file so a crash cannot leave a
  /// truncated `.data` behind (a truncated file would project as a tombstone on
  /// the next reconciliation and delete the login state everywhere).
  static Future<void> _writeAtomically(File target, Uint8List bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      // POSIX rename replaces the destination atomically.
      await tmp.rename(target.path);
    } on FileSystemException {
      // Windows cannot rename over an existing file.
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    }
  }

  static String _fileName(File file) {
    final path = file.path;
    var index = path.lastIndexOf(Platform.pathSeparator);
    final slash = path.lastIndexOf('/');
    if (slash > index) index = slash;
    return index < 0 ? path : path.substring(index + 1);
  }

  /// A source key becomes a file name, so it must never escape [_sourceDir].
  static bool _isSafeStem(String stem) {
    if (stem.isEmpty || stem == '.' || stem == '..') return false;
    for (final unit in stem.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return false;
    }
    return !stem.contains('/') && !stem.contains('\\');
  }

  static bool _isJsonObject(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    try {
      return jsonDecode(utf8.decode(bytes)) is Map;
    } catch (_) {
      return false;
    }
  }

  void _warn(String message) => _onWarning?.call(message);
}
