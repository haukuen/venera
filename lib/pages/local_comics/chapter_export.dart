import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

class ExportableChapter {
  final String id;
  final String title;
  final int position;

  const ExportableChapter({
    required this.id,
    required this.title,
    required this.position,
  });
}

List<ExportableChapter> orderedDownloadedChapters(LocalComic comic) {
  final chapters = comic.chapters;
  if (chapters == null) {
    return [
      for (var i = 0; i < comic.downloadedChapters.length; i++)
        ExportableChapter(
          id: comic.downloadedChapters[i],
          title: comic.downloadedChapters[i],
          position: i + 1,
        ),
    ];
  }

  final downloadedChapterIds = comic.downloadedChapters.toSet();
  final exportableChapters = <ExportableChapter>[];
  var position = 1;
  for (final id in chapters.ids) {
    if (downloadedChapterIds.contains(id)) {
      exportableChapters.add(
        ExportableChapter(
          id: id,
          title: chapters[id] ?? id,
          position: position,
        ),
      );
    }
    position++;
  }
  return exportableChapters;
}

LocalComic copyWithSelectedChapters(
  LocalComic comic,
  List<String> selectedChapterIds,
) {
  return LocalComic(
    id: comic.id,
    title: comic.title,
    subtitle: comic.subtitle,
    tags: comic.tags,
    directory: comic.directory,
    chapters: comic.chapters,
    cover: comic.cover,
    comicType: comic.comicType,
    downloadedChapters: selectedChapterIds,
    createdAt: comic.createdAt,
  );
}

String selectedChapterExportFilename({
  required LocalComic comic,
  required List<ExportableChapter> selectedChapters,
  required String extension,
}) {
  if (selectedChapters.isEmpty) {
    throw ArgumentError.value(
      selectedChapters,
      'selectedChapters',
      'must not be empty',
    );
  }

  final middle = selectedChapters.length == 1
      ? '_EP${selectedChapters.first.title}_1chapter'
      : '_EP${selectedChapters.first.title}-EP${selectedChapters.last.title}_${selectedChapters.length}chapters';

  return sanitizeFileNameWithSuffix(
    comic.title,
    middle: middle,
    extension: extension,
    fallback: 'comic',
  );
}

/// Available naming formats for the chapter segment of split-chapter export
/// filenames (setting key `chapterExportNamingFormat`).
enum ChapterExportNamingFormat {
  /// `Title_EP001_Chapter Title.cbz` — app default.
  ep,

  /// `Title_第001话_Chapter Title.cbz` — recognized by Kavita and most
  /// Chinese comic servers.
  chinese,

  /// `Title_v01_Chapter Title.cbz` — volume-style, for English-oriented
  /// servers.
  volume,

  /// `Title_001_Chapter Title.cbz` — bare zero-padded index only.
  number;

  String get settingKey {
    switch (this) {
      case ep:
        return 'ep';
      case chinese:
        return 'chinese';
      case volume:
        return 'volume';
      case number:
        return 'number';
    }
  }

  static ChapterExportNamingFormat fromSettings() {
    final raw = appdata.settings['chapterExportNamingFormat'];
    for (final format in ChapterExportNamingFormat.values) {
      if (format.settingKey == raw) return format;
    }
    return ChapterExportNamingFormat.ep;
  }
}

/// Prefix of the zero-padded chapter index under [format], e.g. `EP` / `第`
/// (closed by `话`) / `v` / `''`.
String _chapterIndexPrefix(ChapterExportNamingFormat format) {
  switch (format) {
    case ChapterExportNamingFormat.ep:
      return 'EP';
    case ChapterExportNamingFormat.chinese:
      return '第';
    case ChapterExportNamingFormat.volume:
      return 'v';
    case ChapterExportNamingFormat.number:
      return '';
  }
}

String _chapterIndexSuffix(ChapterExportNamingFormat format) {
  return format == ChapterExportNamingFormat.chinese ? '话' : '';
}

/// Build the `middle` segment of a single-chapter export filename under
/// [format]: `{prefix}{index}{suffix}` plus `_{cleanTitle}` when the title
/// sanitizes to non-empty. The index is zero-padded to 3 digits (2 for
/// [ChapterExportNamingFormat.volume], matching common `v01` conventions).
String buildSingleChapterMiddleSegment({
  required ChapterExportNamingFormat format,
  required int position,
  required String chapterTitle,
}) {
  assert(position > 0, 'position must be the 1-based full-table index');
  final digits = format == ChapterExportNamingFormat.volume ? 2 : 3;
  final paddedIndex = position.toString().padLeft(digits, '0');
  final indexText =
      '${_chapterIndexPrefix(format)}$paddedIndex${_chapterIndexSuffix(format)}';
  final cleanTitle = replaceInvalidFileNameChars(chapterTitle).trim();
  return cleanTitle.isEmpty ? '_$indexText' : '_${indexText}_$cleanTitle';
}

/// Generate the filename for a single-chapter CBZ in split-by-chapter mode.
///
/// The chapter segment follows [ChapterExportNamingFormat.fromSettings]
/// (default: `Title_EP001_Chapter Title.cbz`; see that enum for the other
/// formats). The index is [chapter.position] — the chapter's 1-based index in
/// the full chapter table, not the index within the current export batch.
/// Including the index keeps files unique when consecutive chapters share the
/// same title, and zero-padding makes filename sort order match chapter order.
///
/// When [chapter.position] is not positive, falls back to exporting the raw
/// [chapter.title] without an index.
String singleChapterExportFilename({
  required LocalComic comic,
  required ExportableChapter chapter,
  required String extension,
  ChapterExportNamingFormat? format,
}) {
  final effectiveFormat = format ?? ChapterExportNamingFormat.fromSettings();

  final String middle;
  if (chapter.position <= 0) {
    middle = '_EP${chapter.title}';
  } else {
    middle = buildSingleChapterMiddleSegment(
      format: effectiveFormat,
      position: chapter.position,
      chapterTitle: chapter.title,
    );
  }

  return sanitizeFileNameWithSuffix(
    comic.title,
    middle: middle,
    extension: extension,
    fallback: 'comic',
  );
}
