/// App adapter for the `comicSource` domain (protocol v2 §3, blob §6.3).
///
/// Comic source definitions live as immutable `*.js` files in
/// `<App.dataPath>/comic_source`. The record payload only references the
/// content-addressed blob (`sha256` of the uncompressed bytes); the file
/// content is uploaded/downloaded through [BlobSync].
///
/// This file is deliberately pure Dart (`dart:io` + `BlobSync`, no Flutter and
/// no app/business imports) so it can be tested with temp directories and the
/// in-memory fake transport.
library;

import 'dart:io';
import 'dart:typed_data';

import '../../blob_sync.dart';
import '../../domains.dart';
import '../../op.dart';
import '../../store.dart';
import '../sync_app_adapter.dart';

class ComicSourceAdapter implements SyncAppAdapter, SyncBlobAdapter {
  ComicSourceAdapter({
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

  /// Source files are always `<sourceKey>.js`; `.data` sidecars and
  /// directories are not synced.
  static const String sourceExtension = '.js';

  static const Set<String> _domains = <String>{SyncDomains.comicSource};

  @override
  Set<String> get domains => _domains;

  Directory get _directory => Directory(_sourceDir);

  /// Projects every local `*.js` source file as one register.
  ///
  /// Only `sha256`, `size` and the file name go into the payload; the content
  /// itself is uploaded later by [ensureBlobsUploaded], so this method stays
  /// side-effect free.
  @override
  Future<List<AdapterRecord>> readLocalRecords() async {
    final records = <AdapterRecord>[];
    for (final file in _sourceFiles()) {
      try {
        final fileName = _fileName(file);
        final stem = fileName.substring(
          0,
          fileName.length - sourceExtension.length,
        );
        if (!_isSafeStem(stem)) {
          _warn(
            'comicSource: skipping local file with unsafe name "$fileName"',
          );
          continue;
        }
        final bytes = await file.readAsBytes();
        final sha256 = BlobSync.sha256Hex(bytes);
        records.add(
          AdapterRecord(
            domain: SyncDomains.comicSource,
            key: SyncKeys.comicSourceKey(stem),
            field: '',
            kind: SyncOpKind.upsert,
            data: <String, Object?>{
              'sha256': sha256,
              'size': bytes.length,
              'name': fileName,
            },
          ),
        );
      } catch (error) {
        _warn('comicSource: failed to read ${file.path}: $error');
      }
    }
    return records;
  }

  /// Uploads every local source file to this device's blob branch.
  ///
  /// Called by the service before pushing/seeding so the record payload never
  /// references a blob that does not exist remotely. Blobs are immutable and
  /// content-addressed, so repeated calls are cheap (existing blobs are
  /// verified and skipped by [BlobSync.upload]). Returns the number of files
  /// that could not be uploaded; the caller treats that as a failed push.
  @override
  Future<int> ensureBlobsUploaded() async {
    var failed = 0;
    for (final file in _sourceFiles()) {
      try {
        final bytes = await file.readAsBytes();
        await _blobSync.upload(bytes);
      } catch (error) {
        failed++;
        _warn('comicSource: failed to upload ${file.path}: $error');
      }
    }
    return failed;
  }

  /// Projects the merged store state back into the `comic_source` directory.
  ///
  /// Visible records whose blob can be downloaded and verified are written as
  /// `<sourceKey>.js`; files whose key is no longer visible are deleted.
  /// Missing/tampered blobs are skipped with a warning (the existing local file
  /// is left alone so a transient download failure does not destroy a source).
  /// [reload] runs only when the directory actually changed.
  @override
  Future<void> applyRemote(SyncStore store) async {
    final stored = await store.dumpRecords(domains: _domains);
    final desired = <String, String>{};
    final visibleStems = <String>{};
    for (final record in stored) {
      if (!record.visible) continue;
      if (record.field.isNotEmpty) {
        _warn(
          'comicSource: ignoring record with unexpected field '
          '"${record.field}" for ${record.key.encode()}',
        );
        continue;
      }
      final parts = record.key.parts;
      if (parts.length != 1) {
        _warn('comicSource: ignoring malformed key ${record.key.encode()}');
        continue;
      }
      final stem = parts.single;
      if (!_isSafeStem(stem)) {
        _warn('comicSource: ignoring unsafe source key ${record.key.encode()}');
        continue;
      }
      // Even a record with a malformed payload still owns its local file: do
      // not delete it just because the blob reference is broken.
      visibleStems.add(stem);
      final data = record.data;
      final sha256 = data == null ? null : data['sha256'];
      if (sha256 is! String || !BlobSync.sha256Pattern.hasMatch(sha256)) {
        _warn('comicSource: ignoring record with invalid sha256 for "$stem"');
        continue;
      }
      desired[stem] = sha256;
    }

    final directory = _directory;
    var changed = 0;

    if (desired.isNotEmpty) {
      try {
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
      } catch (error) {
        _warn('comicSource: cannot create ${directory.path}: $error');
        return;
      }
      for (final entry in desired.entries) {
        final stem = entry.key;
        final sha256 = entry.value;
        final target = File(
          '${directory.path}${Platform.pathSeparator}$stem$sourceExtension',
        );
        Uint8List? bytes;
        try {
          bytes = await _blobSync.downloadFromAnyDevice(sha256);
        } catch (error) {
          _warn('comicSource: failed to download blob $sha256: $error');
          continue;
        }
        if (bytes == null) {
          _warn(
            'comicSource: blob $sha256 for "$stem" is missing or tampered; '
            'keeping the local file (if any)',
          );
          continue;
        }
        // Defence in depth: BlobSync already verifies, re-check before writing.
        if (BlobSync.sha256Hex(bytes) != sha256) {
          _warn('comicSource: blob $sha256 for "$stem" failed hash check');
          continue;
        }
        try {
          if (await target.exists()) {
            final existing = await target.readAsBytes();
            if (BlobSync.sha256Hex(existing) == sha256) continue;
          }
          await target.writeAsBytes(bytes, flush: true);
          changed++;
        } catch (error) {
          _warn('comicSource: failed to write ${target.path}: $error');
        }
      }
    }

    if (await directory.exists()) {
      try {
        for (final entity in directory.listSync(followLinks: false)) {
          if (entity is! File) continue;
          final fileName = _fileName(entity);
          if (!fileName.endsWith(sourceExtension)) continue;
          final stem = fileName.substring(
            0,
            fileName.length - sourceExtension.length,
          );
          if (visibleStems.contains(stem)) continue;
          try {
            await entity.delete();
            changed++;
          } catch (error) {
            _warn('comicSource: failed to delete ${entity.path}: $error');
          }
        }
      } catch (error) {
        _warn('comicSource: failed to list ${directory.path}: $error');
      }
    }

    if (changed > 0) await _reload?.call();
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

  /// Local source files, sorted for deterministic projections. Missing
  /// directories yield no files; unreadable listings yield a warning.
  List<File> _sourceFiles() {
    final directory = _directory;
    if (!directory.existsSync()) return const <File>[];
    final files = <File>[];
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith(sourceExtension)) continue;
        if (_fileName(entity) == sourceExtension) {
          _warn('comicSource: skipping file without a source key');
          continue;
        }
        files.add(entity);
      }
    } catch (error) {
      _warn('comicSource: failed to list ${directory.path}: $error');
      return const <File>[];
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// File name without any directory component, using the platform separator.
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

  void _warn(String message) => _onWarning?.call(message);
}
