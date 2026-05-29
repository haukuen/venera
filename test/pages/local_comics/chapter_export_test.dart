import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/local_comics/chapter_export.dart';

LocalComic _comic({
  String title = 'Test Comic',
  ComicChapters? chapters,
  bool hasChapterMetadata = true,
  List<String> downloadedChapters = const ['1', '2', '3', '4'],
}) {
  return LocalComic(
    id: 'comic-id',
    title: title,
    subtitle: 'Author',
    tags: const ['tag'],
    directory: 'comic-dir',
    chapters: hasChapterMetadata
        ? chapters ??
              const ComicChapters({
                '1': '001',
                '2': '002',
                '3': '003',
                '4': '004',
              })
        : null,
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: downloadedChapters,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  group('orderedDownloadedChapters', () {
    test('keeps comic chapter order and filters unavailable downloads', () {
      final comic = _comic(downloadedChapters: const ['3', '1']);

      final chapters = orderedDownloadedChapters(comic);

      expect(chapters.map((e) => e.id), ['1', '3']);
      expect(chapters.map((e) => e.title), ['001', '003']);
      expect(chapters.map((e) => e.position), [1, 3]);
    });

    test('falls back to downloaded order when chapter metadata is missing', () {
      final comic = _comic(
        hasChapterMetadata: false,
        downloadedChapters: const ['9', '7'],
      );

      final chapters = orderedDownloadedChapters(comic);

      expect(chapters.map((e) => e.id), ['9', '7']);
      expect(chapters.map((e) => e.title), ['9', '7']);
      expect(chapters.map((e) => e.position), [1, 2]);
    });

    test('flattens grouped chapters in source order', () {
      final comic = _comic(
        chapters: const ComicChapters.grouped({
          'Volume 1': {'1': '001', '2': '002'},
          'Volume 2': {'3': '003', '4': '004'},
        }),
        downloadedChapters: const ['4', '2'],
      );

      final chapters = orderedDownloadedChapters(comic);

      expect(chapters.map((e) => e.id), ['2', '4']);
      expect(chapters.map((e) => e.title), ['002', '004']);
      expect(chapters.map((e) => e.position), [2, 4]);
    });
  });

  group('copyWithSelectedChapters', () {
    test('returns a LocalComic with only selected chapter ids', () {
      final comic = _comic();

      final filtered = copyWithSelectedChapters(comic, const ['1', '3']);

      expect(filtered.downloadedChapters, ['1', '3']);
      expect(filtered.id, comic.id);
      expect(filtered.title, comic.title);
      expect(filtered.chapters, same(comic.chapters));
      expect(filtered.comicType, comic.comicType);
    });
  });

  group('selectedChapterExportFilename', () {
    test('uses first-last-count for non-contiguous selected chapters', () {
      final comic = _comic();
      final chapters = orderedDownloadedChapters(
        comic,
      ).where((chapter) => const {'1', '3', '4'}.contains(chapter.id)).toList();

      final filename = selectedChapterExportFilename(
        comic: comic,
        selectedChapters: chapters,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_EP001-EP004_3chapters.cbz');
    });

    test('uses singular chapter suffix for one selected chapter', () {
      final comic = _comic();
      final chapters = orderedDownloadedChapters(
        comic,
      ).where((chapter) => chapter.id == '2').toList();

      final filename = selectedChapterExportFilename(
        comic: comic,
        selectedChapters: chapters,
        extension: '.pdf',
      );

      expect(filename, 'Test Comic_EP002_1chapter.pdf');
    });

    test('sanitizes chapter titles used in the middle segment', () {
      final comic = _comic(
        chapters: const ComicChapters({'1': '第1话/前篇', '2': '第2话:后篇'}),
      );
      final chapters = orderedDownloadedChapters(comic);

      final filename = selectedChapterExportFilename(
        comic: comic,
        selectedChapters: chapters,
        extension: '.epub',
      );

      expect(filename.contains('/'), isFalse);
      expect(filename.contains(':'), isFalse);
      expect(filename.contains('EP第1话 前篇-EP第2话 后篇'), isTrue);
      expect(filename.endsWith('_2chapters.epub'), isTrue);
    });

    test('keeps long comic title within filename constraints', () {
      final comic = _comic(
        title: '漫画标题' * 40,
        chapters: const ComicChapters({'1': '001', '4': '004'}),
        downloadedChapters: const ['1', '4'],
      );
      final chapters = orderedDownloadedChapters(comic);

      final filename = selectedChapterExportFilename(
        comic: comic,
        selectedChapters: chapters,
        extension: '.cbz',
      );

      expect(filename.endsWith('_EP001-EP004_2chapters.cbz'), isTrue);
      expect(filename.length, lessThanOrEqualTo(255));
    });
  });
}
