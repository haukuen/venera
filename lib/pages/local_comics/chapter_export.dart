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
