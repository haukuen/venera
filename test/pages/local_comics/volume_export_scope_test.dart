import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

// Mirror of the private _canSplitByChapters logic for direct testing.
bool canSplitByChapters(LocalComic comic) {
  final chapters = comic.chapters;
  if (chapters == null) return false;
  final downloadedSet = comic.downloadedChapters.toSet();
  var count = 0;
  for (final id in chapters.ids) {
    if (downloadedSet.contains(id)) {
      count++;
      if (count >= 2) return true;
    }
  }
  return false;
}

LocalComic _comic({
  ComicChapters? chapters,
  List<String> downloadedChapters = const ['1', '2', '3', '4'],
  bool hasChapters = true,
}) {
  return LocalComic(
    id: 'id',
    title: 'T',
    subtitle: '',
    tags: const [],
    directory: 'd',
    chapters: hasChapters
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
  group('canSplitByChapters predicate', () {
    test('returns false when chapters is null', () {
      expect(canSplitByChapters(_comic(hasChapters: false)), isFalse);
    });

    test('returns false when fewer than 2 chapters downloaded', () {
      expect(
        canSplitByChapters(_comic(downloadedChapters: const ['1'])),
        isFalse,
      );
    });

    test('returns true for flat comic with >= 2 downloaded chapters', () {
      expect(canSplitByChapters(_comic()), isTrue);
    });

    test('returns true for grouped comic with >= 2 downloaded chapters', () {
      final comic = _comic(
        chapters: const ComicChapters.grouped({
          'Volume 1': {'1': '001', '2': '002'},
          'Volume 2': {'3': '003', '4': '004'},
        }),
        downloadedChapters: const ['1', '3'],
      );
      expect(canSplitByChapters(comic), isTrue);
    });

    test('returns false when nothing downloaded', () {
      expect(canSplitByChapters(_comic(downloadedChapters: const [])), isFalse);
    });
  });
}
