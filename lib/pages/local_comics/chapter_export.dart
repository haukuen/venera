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

/// Generate the filename for a single-chapter CBZ in split-by-chapter mode.
///
/// Produces `Title_EP001.cbz` when [chapter.title] is empty, or
/// `Title_EP001_Chapter Title.cbz` otherwise. `001` is [chapter.position]
/// zero-padded to 3 digits — the chapter's 1-based index in the full chapter
/// table, not the index within the current export batch. Including the index
/// keeps files unique when consecutive chapters share the same title, and
/// zero-padding makes filename sort order match chapter order.
///
/// When [chapter.position] is not positive, falls back to exporting the raw
/// [chapter.title] without an index.
String singleChapterExportFilename({
  required LocalComic comic,
  required ExportableChapter chapter,
  required String extension,
}) {
  final paddedIndex = chapter.position > 0
      ? chapter.position.toString().padLeft(3, '0')
      : null;

  final String middle;
  if (paddedIndex == null) {
    middle = '_EP${chapter.title}';
  } else if (chapter.title.trim().isEmpty) {
    middle = '_EP$paddedIndex';
  } else {
    final cleanTitle = replaceInvalidFileNameChars(chapter.title).trim();
    middle = cleanTitle.isEmpty
        ? '_EP$paddedIndex'
        : '_EP${paddedIndex}_$cleanTitle';
  }

  return sanitizeFileNameWithSuffix(
    comic.title,
    middle: middle,
    extension: extension,
    fallback: 'comic',
  );
}
