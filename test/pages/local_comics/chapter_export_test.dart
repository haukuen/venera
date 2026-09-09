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

  group('singleChapterExportFilename', () {
    test('embeds zero-padded chapter position and title', () {
      final comic = _comic();
      final chapter = orderedDownloadedChapters(comic).first;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_EP001_001.cbz');
    });

    test('produces distinct filenames for duplicate chapter titles', () {
      final comic = _comic(
        chapters: const ComicChapters({'1': '番外篇', '2': '番外篇', '3': '番外篇'}),
        downloadedChapters: const ['1', '2', '3'],
      );
      final chapters = orderedDownloadedChapters(comic);

      final filenames = chapters
          .map(
            (chapter) => singleChapterExportFilename(
              comic: comic,
              chapter: chapter,
              extension: '.cbz',
            ),
          )
          .toList();

      expect(filenames, hasLength(3));
      expect(filenames.toSet().length, 3);
      expect(filenames[0], 'Test Comic_EP001_番外篇.cbz');
      expect(filenames[1], 'Test Comic_EP002_番外篇.cbz');
      expect(filenames[2], 'Test Comic_EP003_番外篇.cbz');
    });

    test('uses full-table position, not export-batch order', () {
      final comic = _comic(
        chapters: const ComicChapters({'1': '001', '2': '002', '3': '003'}),
        downloadedChapters: const ['3'],
      );
      final chapter = orderedDownloadedChapters(comic).single;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_EP003_003.cbz');
    });

    test('omits title segment when chapter title sanitizes to empty', () {
      final comic = _comic(chapters: const ComicChapters({'1': '///:::'}));
      final chapter = orderedDownloadedChapters(comic).single;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_EP001.cbz');
    });

    test('sanitizes invalid characters in chapter title', () {
      final comic = _comic(chapters: const ComicChapters({'1': '第1话/前篇:序'}));
      final chapter = orderedDownloadedChapters(comic).single;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_EP001_第1话 前篇 序.cbz');
    });

    test('falls back to raw title when position is not positive', () {
      final comic = _comic();
      const chapter = ExportableChapter(id: 'x', title: '番外篇', position: 0);

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_EP番外篇.cbz');
    });
  });

  group('singleChapterExportFilename naming formats', () {
    final comic = _comic(
      chapters: const ComicChapters({'1': '温泉节', '2': '番外篇'}),
    );

    test('ep format (default) produces EP001 segment', () {
      final chapter = orderedDownloadedChapters(comic).first;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
        format: ChapterExportNamingFormat.ep,
      );

      expect(filename, 'Test Comic_EP001_温泉节.cbz');
    });

    test('chinese format produces 第001话 segment (Kavita-compatible)', () {
      final chapter = orderedDownloadedChapters(comic).first;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
        format: ChapterExportNamingFormat.chinese,
      );

      expect(filename, 'Test Comic_第001话_温泉节.cbz');
    });

    test('volume format produces 2-digit v01 segment', () {
      final chapter = orderedDownloadedChapters(comic).first;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
        format: ChapterExportNamingFormat.volume,
      );

      expect(filename, 'Test Comic_v01_温泉节.cbz');
    });

    test('number format produces bare 001 segment', () {
      final chapter = orderedDownloadedChapters(comic).first;

      final filename = singleChapterExportFilename(
        comic: comic,
        chapter: chapter,
        extension: '.cbz',
        format: ChapterExportNamingFormat.number,
      );

      expect(filename, 'Test Comic_001_温泉节.cbz');
    });

    test('all formats stay unique for duplicate chapter titles', () {
      final dupComic = _comic(
        chapters: const ComicChapters({'1': '番外篇', '2': '番外篇'}),
      );
      final chapters = orderedDownloadedChapters(dupComic);

      for (final format in ChapterExportNamingFormat.values) {
        final names = chapters
            .map(
              (c) => singleChapterExportFilename(
                comic: dupComic,
                chapter: c,
                extension: '.cbz',
                format: format,
              ),
            )
            .toSet();
        expect(names, hasLength(2), reason: format.name);
      }
    });

    test(
      'chinese format omits title segment when title sanitizes to empty',
      () {
        final emptyTitleComic = _comic(
          chapters: const ComicChapters({'1': '///:::'}),
        );
        final chapter = orderedDownloadedChapters(emptyTitleComic).single;

        final filename = singleChapterExportFilename(
          comic: emptyTitleComic,
          chapter: chapter,
          extension: '.cbz',
          format: ChapterExportNamingFormat.chinese,
        );

        expect(filename, 'Test Comic_第001话.cbz');
      },
    );
  });
}
