import 'dart:convert';
import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/pages/local_comics/chapter_export.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ComicMetaData {
  final String title;

  final String author;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      author = json['author'],
      tags = List<String>.from(json['tags']),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      start = json['start'],
      end = json['end'];

  ComicChapter({required this.title, required this.start, required this.end});
}

/// Result of a multi-volume CBZ export.
class VolumeExportResult {
  /// Successfully generated CBZ files, in production order.
  final List<File> files;

  /// Failure reasons, each formatted as "Vol`NN`: `reason`".
  final List<String> errors;

  VolumeExportResult({required this.files, required this.errors});

  bool get allFailed => files.isEmpty && errors.isNotEmpty;

  bool get partialSuccess => files.isNotEmpty && errors.isNotEmpty;
}

/// Image extensions accepted when packing a CBZ. Mirrors the filter used by
/// [CBZ.import]. Lower-cased, without the leading dot.
const _cbzImageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'];

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    var fileType = await checkType(file);
    if (fileType.mime == 'application/zip') {
      await ZipFile.openAndExtractAsync(file.path, out.path, 4);
    } else if (fileType.mime == "application/x-7z-compressed") {
      await SZArchive.extractIsolates(file.path, out.path, 4);
    } else {
      throw Exception('Unsupported archive type');
    }
  }

  static Future<LocalComic> import(File file) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_import'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    await extractArchive(file, cache);
    var f = cache.listSync();
    if (f.length == 1 && f.first is Directory) {
      cache = f.first as Directory;
    }
    var metaDataFile = File(FilePath.join(cache.path, 'metadata.json'));
    ComicMetaData? metaData;
    if (metaDataFile.existsSync()) {
      try {
        metaData = ComicMetaData.fromJson(
          jsonDecode(metaDataFile.readAsStringSync()),
        );
      } catch (e) {
        Log.warning("CBZ", "Failed to parse metadata: $e");
      }
    }
    metaData ??= ComicMetaData(
      title: file.name.substring(0, file.name.lastIndexOf('.')),
      author: "",
      tags: [],
    );
    var old = LocalManager().findByName(metaData.title);
    if (old != null) {
      throw Exception('Comic with name ${metaData.title} already exists');
    }
    var files = cache.listSync().whereType<File>().toList();
    files.removeWhere((e) {
      var ext = e.path.split('.').last.toLowerCase();
      return !_cbzImageExtensions.contains(ext);
    });
    if (files.isEmpty) {
      cache.deleteSync(recursive: true);
      throw Exception('No images found in the archive');
    }
    files.sort((a, b) {
      var aName = a.basenameWithoutExt;
      var bName = b.basenameWithoutExt;
      var aIndex = int.tryParse(aName);
      var bIndex = int.tryParse(bName);
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      } else {
        return a.path.compareTo(b.path);
      }
    });
    var coverFile = files.firstWhereOrNull(
      (element) =>
          element.path.endsWith('cover.${element.path.split('.').last}'),
    );
    if (coverFile != null) {
      files.remove(coverFile);
    } else {
      coverFile = files.first;
    }
    Map<String, String>? cpMap;
    var dest = Directory(
      FilePath.join(
        LocalManager().path,
        sanitizeFileName(metaData.title, maxLength: maxSanitizedFileNameLength),
      ),
    );
    dest.createSync();
    coverFile.copyMem(FilePath.join(dest.path, 'cover.${coverFile.extension}'));
    if (metaData.chapters == null) {
      for (var i = 0; i < files.length; i++) {
        var src = files[i];
        var dst = File(
          FilePath.join(dest.path, '${i + 1}.${src.path.split('.').last}'),
        );
        await src.copyMem(dst.path);
      }
    } else {
      dest.createSync();
      var chapters = <String, List<File>>{};
      for (var chapter in metaData.chapters!) {
        chapters[chapter.title] = files.sublist(chapter.start - 1, chapter.end);
      }
      int i = 0;
      cpMap = <String, String>{};
      for (var chapter in chapters.entries) {
        cpMap[i.toString()] = chapter.key;
        var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
        chapterDir.createSync();
        for (var j = 0; j < chapter.value.length; j++) {
          var src = chapter.value[j];
          var dst = File(
            FilePath.join(
              chapterDir.path,
              '${j + 1}.${src.path.split('.').last}',
            ),
          );
          await src.copyMem(dst.path);
        }
        i++;
      }
    }
    var comic = LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: metaData.title,
      subtitle: metaData.author,
      tags: metaData.tags,
      comicType: ComicType.local,
      directory: dest.name,
      chapters: ComicChapters.fromJsonOrNull(cpMap),
      downloadedChapters: cpMap?.keys.toList() ?? [],
      cover: 'cover.${coverFile.extension}',
      createdAt: DateTime.now(),
    );
    await cache.delete(recursive: true);
    return comic;
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_export'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    try {
      if (comic.chapters == null) {
        var images = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          1,
        );
        if (images.isEmpty) {
          throw StateError(
            'No images found on disk for "${comic.title}". '
            'The comic may not have been fully downloaded. '
            'Please delete and re-download.',
          );
        }
        var pageCount = images.length;
        int i = 1;
        for (var image in images) {
          var src = File(_localFilePathFromImageUri(image));
          var dstName = compatiblePageFileName(i, image.split('.').last);
          var dst = File(FilePath.join(cache.path, dstName));
          await src.copyMem(dst.path);
          i++;
        }
        var cover = comic.coverFile;
        await cover.copyMem(
          FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
        );
        final metaData = ComicMetaData(
          title: comic.title,
          author: comic.subtitle,
          tags: comic.tags,
          chapters: null,
        );
        await File(
          FilePath.join(cache.path, 'metadata.json'),
        ).writeAsString(jsonEncode(metaData));
        await File(
          FilePath.join(cache.path, 'ComicInfo.xml'),
        ).writeAsString(_buildComicInfoXml(metaData, pageCount: pageCount));
        var cbz = File(outFilePath);
        if (cbz.existsSync()) cbz.deleteSync();
        await _compress(cache.path, cbz.path);
        return cbz;
      } else {
        // 按章节原始顺序遍历,而非 downloadedChapters(其顺序可能是完成顺序)。
        var downloadedSet = comic.downloadedChapters.toSet();
        var orderedIds = comic.chapters!.ids.where(
          (c) => downloadedSet.contains(c),
        );
        var availableChapters = _collectAvailableChapters(comic, orderedIds);
        if (availableChapters.isEmpty) {
          throw StateError(
            'No downloadable chapters found on disk for "${comic.title}". '
            'Please delete and re-download the comic.',
          );
        }
        var cbz = await _exportChaptersToCbz(
          comic,
          availableChapters,
          outFilePath,
          cache: cache,
          includeCover: true,
        );
        return cbz;
      }
    } finally {
      cache.deleteSync(recursive: true);
    }
  }

  static String compatiblePageFileName(int pageIndex, String extension) {
    final normalizedExtension = extension.startsWith('.')
        ? extension.substring(1)
        : extension;
    return '${pageIndex.toString().padLeft(4, '0')}.$normalizedExtension';
  }

  static String localFilePathFromImageUriForTesting(String imageUri) {
    return _localFilePathFromImageUri(imageUri);
  }

  static String _localFilePathFromImageUri(String imageUri) {
    return imageUri.replaceFirst('file://', '');
  }

  static List<ComicChapter> buildChapterRangesForTesting(
    Map<String, int> chapterPageCounts,
  ) {
    return _buildChapterRanges(chapterPageCounts.entries);
  }

  /// Collect chapters from [chapterIds] that are both downloaded and present
  /// on disk, preserving the input order. Returns warnings for missing ones
  /// via [Log.warning].
  static List<String> _collectAvailableChapters(
    LocalComic comic,
    Iterable<String> chapterIds,
  ) {
    var availableChapters = <String>[];
    var missingChapters = <String>[];
    for (var c in chapterIds) {
      var chapterDir = Directory(
        FilePath.join(comic.baseDir, LocalManager.getChapterDirectoryName(c)),
      );
      if (chapterDir.existsSync()) {
        availableChapters.add(c);
      } else {
        missingChapters.add(c);
      }
    }
    if (missingChapters.isNotEmpty) {
      var missingTitles = missingChapters.map((c) => comic.chapters![c] ?? c);
      Log.warning(
        'CBZ',
        'Skipped missing chapters for "${comic.title}": ${missingTitles.join(', ')}',
      );
    }
    return availableChapters;
  }

  static List<String> collectAvailableChaptersForTesting(
    LocalComic comic,
    Iterable<String> chapterIds,
  ) {
    return _collectAvailableChapters(comic, chapterIds);
  }

  /// List image URIs (file://...) for a single chapter of [comic] by reading
  /// directly from disk, mirroring [LocalManager.getImages] without the DB
  /// lookup. The [comic] passed in is authoritative.
  ///
  /// - For chaptered comics, reads from `<baseDir>/<chapterDir(c)>`.
  /// - For non-chaptered comics, reads from `<baseDir>`.
  /// - Skips files starting with `cover.` or `.`.
  /// - Sorts by integer prefix when both names parse, else lexicographically.
  static Future<List<String>> _listChapterImages(
    LocalComic comic,
    String chapterId,
  ) async {
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = LocalManager.getChapterDirectoryName(chapterId);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    if (!await directory.exists()) {
      throw StateError(
        'Chapter directory not found: ${directory.path}. '
        'The chapter may not have been fully downloaded. '
        'Please delete and re-download the affected chapters.',
      );
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        if (entity.name.startsWith('.')) {
          continue;
        }
        // Skip non-image files (metadata.json, Thumbs.db, etc.) that may
        // exist alongside the pages. Mirrors [CBZ.import]'s filter.
        final ext = entity.path.split('.').last.toLowerCase();
        if (!_cbzImageExtensions.contains(ext)) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  /// Export a subset of [comic]'s chapters as a single CBZ file.
  ///
  /// - Pages are numbered from 0001 within this CBZ.
  /// - metadata.json and ComicInfo.xml only contain [chapterIds]' chapters.
  /// - [includeCover] controls whether cover.* is written.
  /// - [cache] must be an existing empty directory owned by the caller;
  ///   the caller is responsible for creating and deleting it.
  static Future<File> _exportChaptersToCbz(
    LocalComic comic,
    List<String> chapterIds,
    String outFilePath, {
    required Directory cache,
    bool includeCover = true,
  }) async {
    if (chapterIds.isEmpty) {
      throw StateError('No chapters to export for "${comic.title}".');
    }
    var allImages = <String>[];
    final chapterPageCounts = <MapEntry<String, int>>[];
    for (var c in chapterIds) {
      final chapterName = comic.chapters![c] ?? c;
      var images = await _listChapterImages(comic, c);
      allImages.addAll(images);
      chapterPageCounts.add(MapEntry(chapterName, images.length));
    }
    final chapters = _buildChapterRanges(chapterPageCounts);
    final pageCount = allImages.length;
    int i = 1;
    for (var image in allImages) {
      var src = File(_localFilePathFromImageUri(image));
      var dstName = compatiblePageFileName(i, image.split('.').last);
      var dst = File(FilePath.join(cache.path, dstName));
      await src.copyMem(dst.path);
      i++;
    }
    if (includeCover) {
      var cover = comic.coverFile;
      await cover.copyMem(
        FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
      );
    }
    final metaData = ComicMetaData(
      title: comic.title,
      author: comic.subtitle,
      tags: comic.tags,
      chapters: chapters,
    );
    await File(
      FilePath.join(cache.path, 'metadata.json'),
    ).writeAsString(jsonEncode(metaData));
    await File(
      FilePath.join(cache.path, 'ComicInfo.xml'),
    ).writeAsString(_buildComicInfoXml(metaData, pageCount: pageCount));
    var cbz = File(outFilePath);
    if (cbz.existsSync()) cbz.deleteSync();
    await _compress(cache.path, cbz.path);
    return cbz;
  }

  /// Export [comic] as multiple CBZ files, one per downloaded chapter, into
  /// [outDir].
  ///
  /// - [outDir] must exist and be writable.
  /// - [onProgress] is called before each chapter with (completed, total,
  ///   currentLabel) where total counts only chapters with on-disk images.
  /// - [isCancelled], if it returns true, stops before the next chapter;
  ///   already-produced files are kept.
  /// - Only the first produced CBZ includes the cover.
  /// - A single chapter failure does not abort the rest; failures are
  ///   recorded in [VolumeExportResult.errors].
  /// - Throws [StateError] if [comic.chapters] is null.
  /// - Throws [StateError] if no chapters have on-disk images.
  static Future<VolumeExportResult> exportByChapters(
    LocalComic comic,
    String outDir, {
    void Function(int completed, int total, String currentLabel)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (comic.chapters == null) {
      throw StateError('exportByChapters requires a comic with chapters.');
    }
    final downloadedSet = comic.downloadedChapters.toSet();
    final orderedIds = comic.chapters!.ids.where(
      (id) => downloadedSet.contains(id),
    );
    final availableChapters = _collectAvailableChapters(comic, orderedIds);

    if (availableChapters.isEmpty) {
      throw StateError(
        'No downloadable chapters found on disk for "${comic.title}". '
        'Please delete and re-download the comic.',
      );
    }

    final total = availableChapters.length;
    final files = <File>[];
    final errors = <String>[];
    var completed = 0;
    var coverGiven = false;

    for (var i = 0; i < availableChapters.length; i++) {
      final chapterId = availableChapters[i];
      final chapterTitle = comic.chapters![chapterId] ?? chapterId;
      final epLabel = 'EP$chapterTitle';

      if (isCancelled?.call() == true) break;

      onProgress?.call(completed, total, chapterTitle);

      // Build single-chapter ExportableChapter for filename.
      final exportableChapter = ExportableChapter(
        id: chapterId,
        title: chapterTitle,
        position: i + 1,
      );
      final fileName = singleChapterExportFilename(
        comic: comic,
        chapter: exportableChapter,
        extension: '.cbz',
      );
      final outPath = FilePath.join(outDir, fileName);
      // Compress to a cache-local temp path first, then copy to outPath.
      // On Android/iOS the outDir may be a SAF/security-scoped path that
      // native zip (and plain dart:io outside overrideIO) cannot write to
      // directly. The cache is always natively writable.
      final tempCbzPath = FilePath.join(App.cachePath, 'cbz_export_tmp.cbz');

      var cache = Directory(FilePath.join(App.cachePath, 'cbz_export'));
      if (cache.existsSync()) cache.deleteSync(recursive: true);
      cache.createSync();
      try {
        await _exportChaptersToCbz(
          comic,
          [chapterId],
          tempCbzPath,
          cache: cache,
          includeCover: !coverGiven,
        );
        // Copy the finished CBZ to the user-chosen directory via overrideIO
        // so SAF/security-scoped paths are handled correctly.
        await overrideIO(() async {
          await File(tempCbzPath).copyMem(outPath);
        });
        files.add(File(outPath));
        if (!coverGiven) coverGiven = true;
      } catch (e) {
        errors.add('$epLabel: $e');
      } finally {
        cache.deleteSync(recursive: true);
        File(tempCbzPath).deleteIgnoreError();
      }
      completed++;
    }

    return VolumeExportResult(files: files, errors: errors);
  }

  static List<ComicChapter> _buildChapterRanges(
    Iterable<MapEntry<String, int>> chapterPageCounts,
  ) {
    final chapters = <ComicChapter>[];
    var nextPage = 1;
    for (final chapter in chapterPageCounts) {
      final start = nextPage;
      final end = start + chapter.value - 1;
      chapters.add(ComicChapter(title: chapter.key, start: start, end: end));
      nextPage = end + 1;
    }
    return chapters;
  }

  static String buildComicInfoXmlForTesting(
    ComicMetaData data, {
    required int pageCount,
  }) {
    return _buildComicInfoXml(data, pageCount: pageCount);
  }

  static String _buildComicInfoXml(
    ComicMetaData data, {
    required int pageCount,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    final comicInfoTags = _buildComicInfoTags(data);

    if (comicInfoTags.writer.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(comicInfoTags.writer)}</Writer>');
    }

    if (comicInfoTags.genres.isNotEmpty) {
      buffer.writeln(
        '  <Genre>${_escapeXml(comicInfoTags.genres.join(', '))}</Genre>',
      );
    }

    if (comicInfoTags.tags.isNotEmpty) {
      buffer.writeln(
        '  <Tags>${_escapeXml(comicInfoTags.tags.join(', '))}</Tags>',
      );
    }

    buffer.writeln('  <PageCount>$pageCount</PageCount>');

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    if (pageCount > 0) {
      buffer.writeln('  <Pages>');
      for (var i = 0; i < pageCount; i++) {
        buffer.writeln('    <Page Image="$i" Type="Story" />');
      }
      buffer.writeln('  </Pages>');
    }

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _ComicInfoTags _buildComicInfoTags(ComicMetaData data) {
    final writers = <String>[];
    if (data.author.isNotEmpty) {
      writers.add(data.author);
    }

    final genres = <String>[];
    final tags = <String>[];

    for (final tag in data.tags) {
      final normalizedTag = tag.trim();
      if (normalizedTag.isEmpty) continue;

      final separator = normalizedTag.indexOf(':');
      if (separator <= 0) {
        tags.add(normalizedTag);
        continue;
      }

      final key = normalizedTag.substring(0, separator).trim().toLowerCase();
      final value = normalizedTag.substring(separator + 1).trim();
      if (value.isEmpty) continue;

      switch (key) {
        case 'author':
        case 'authors':
        case 'artist':
        case 'artists':
          writers.addAll(_splitComicInfoValues(value));
        case 'category':
        case 'categories':
        case 'genre':
        case 'genres':
          genres.addAll(_splitComicInfoValues(value));
        case 'tag':
        case 'tags':
          tags.addAll(_splitComicInfoValues(value));
        default:
          tags.add(normalizedTag);
      }
    }

    return _ComicInfoTags(
      writer: _uniqueValues(writers).join(', '),
      genres: _uniqueValues(genres),
      tags: _uniqueValues(tags),
    );
  }

  static List<String> _splitComicInfoValues(String value) {
    return value
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static List<String> _uniqueValues(List<String> values) {
    return values.toSet().toList();
  }

  /// Compress a directory into a CBZ/ZIP archive. Defaults to the native
  /// [ZipFile.compressFolderAsync]; overridable via [compressor] to enable
  /// unit testing without the native zip dynamic library.
  static Future<void> Function(String src, String dst) compressor =
      _defaultCompressor;

  static Future<void> _defaultCompressor(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }

  static _compress(String src, String dst) async {
    await compressor(src, dst);
  }
}

class _ComicInfoTags {
  final String writer;

  final List<String> genres;

  final List<String> tags;

  _ComicInfoTags({
    required this.writer,
    required this.genres,
    required this.tags,
  });
}
