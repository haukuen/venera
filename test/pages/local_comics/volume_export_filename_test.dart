import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/local_comics/chapter_export.dart';

LocalComic _comic({
  String title = 'Test Comic',
  ComicChapters? chapters,
}) {
  return LocalComic(
    id: 'comic-id',
    title: title,
    subtitle: 'Author',
    tags: const ['tag'],
    directory: 'comic-dir',
    chapters: chapters ??
        const ComicChapters({'1': '001', '2': '002', '3': '003', '4': '004'}),
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: const ['1', '2', '3', '4'],
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  group('volumeExportFilename', () {
    test('single chapter volume uses singular suffix', () {
      final comic = _comic();
      final chapters = orderedDownloadedChapters(comic).take(1).toList();

      final filename = volumeExportFilename(
        comic: comic,
        volumeNumber: 1,
        selectedChapters: chapters,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_Vol01_EP001_1chapter.cbz');
    });

    test('multi chapter volume uses range suffix', () {
      final comic = _comic();
      final chapters = orderedDownloadedChapters(comic)
          .where((c) => const ['1', '2', '3'].contains(c.id))
          .toList();

      final filename = volumeExportFilename(
        comic: comic,
        volumeNumber: 2,
        selectedChapters: chapters,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_Vol02_EP001-EP003_3chapters.cbz');
    });

    test('preserves original volume number with gap', () {
      final comic = _comic();
      final chapters = orderedDownloadedChapters(comic).take(1).toList();

      final filename = volumeExportFilename(
        comic: comic,
        volumeNumber: 3,
        selectedChapters: chapters,
        extension: '.cbz',
      );

      expect(filename, 'Test Comic_Vol03_EP001_1chapter.cbz');
    });

    test('pads volume number to two digits', () {
      final comic = _comic();
      final chapters = orderedDownloadedChapters(comic).take(1).toList();

      final filename = volumeExportFilename(
        comic: comic,
        volumeNumber: 5,
        selectedChapters: chapters,
        extension: '.cbz',
      );

      expect(filename.contains('Vol05'), isTrue);
    });

    test('rejects empty chapter list', () {
      final comic = _comic();

      expect(
        () => volumeExportFilename(
          comic: comic,
          volumeNumber: 1,
          selectedChapters: const [],
          extension: '.cbz',
        ),
        throwsArgumentError,
      );
    });
  });
}
