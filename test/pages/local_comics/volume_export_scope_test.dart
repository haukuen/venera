import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

// Mirror of the private _canSplitByGroups logic for direct testing.
// The real function is private in local_comics_page.dart; we test the
// same predicate here to lock the contract.
bool canSplitByGroups(LocalComic comic) {
  final chapters = comic.chapters;
  if (chapters == null || !chapters.isGrouped) return false;
  final downloadedSet = comic.downloadedChapters.toSet();
  var nonEmptyGroups = 0;
  for (var i = 0; i < chapters.groupCount; i++) {
    final group = chapters.getGroupByIndex(i);
    if (group.keys.any((id) => downloadedSet.contains(id))) {
      nonEmptyGroups++;
      if (nonEmptyGroups >= 2) return true;
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
              const ComicChapters({'1': '001', '2': '002', '3': '003', '4': '004'})
        : null,
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: downloadedChapters,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  group('canSplitByGroups predicate', () {
    test('returns false when chapters is null', () {
      expect(canSplitByGroups(_comic(hasChapters: false)), isFalse);
    });

    test('returns false when chapters are flat (not grouped)', () {
      expect(canSplitByGroups(_comic()), isFalse);
    });

    test('returns false when only one group has downloads', () {
      final comic = _comic(
        chapters: const ComicChapters.grouped({
          'Volume 1': {'1': '001', '2': '002'},
          'Volume 2': {'3': '003', '4': '004'},
        }),
        downloadedChapters: const ['1', '2'],
      );
      expect(canSplitByGroups(comic), isFalse);
    });

    test('returns true when two groups each have downloads', () {
      final comic = _comic(
        chapters: const ComicChapters.grouped({
          'Volume 1': {'1': '001', '2': '002'},
          'Volume 2': {'3': '003', '4': '004'},
        }),
        downloadedChapters: const ['1', '3'],
      );
      expect(canSplitByGroups(comic), isTrue);
    });

    test('returns false when grouped but nothing downloaded', () {
      final comic = _comic(
        chapters: const ComicChapters.grouped({
          'Volume 1': {'1': '001'},
          'Volume 2': {'2': '002'},
        }),
        downloadedChapters: const [],
      );
      expect(canSplitByGroups(comic), isFalse);
    });
  });
}
