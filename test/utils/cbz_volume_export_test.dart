import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/cbz.dart';

LocalComic _groupedComic({
  String title = 'Grouped Comic',
  Map<String, Map<String, String>> grouped = const {
    'Volume 1': {'1': '001', '2': '002'},
    'Volume 2': {'3': '003', '4': '004'},
    'Volume 3': {'5': '005', '6': '006'},
  },
  List<String> downloadedChapters = const ['1', '2', '3', '4', '5', '6'],
}) {
  return LocalComic(
    id: 'grouped-id',
    title: title,
    subtitle: 'Author',
    tags: const ['tag'],
    directory: 'grouped-dir',
    chapters: ComicChapters.grouped(grouped),
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: downloadedChapters,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  group('_collectAvailableChapters (via ForTesting)', () {
    test('returns all when all chapter dirs exist', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        LocalManager().path = tmpRoot.path;
        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        for (final name in ['1', '2', '3', '4']) {
          final d = Directory('${comicDir.path}/$name');
          await d.create();
          await File('${d.path}/1.jpg').writeAsBytes([1]);
        }
        final comic = _groupedComic();

        final result = CBZ.collectAvailableChaptersForTesting(comic, const [
          '1',
          '2',
          '3',
          '4',
        ]);

        expect(result, ['1', '2', '3', '4']);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('filters out chapters whose dir is missing', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        LocalManager().path = tmpRoot.path;
        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        // Only create dir for chapter '1' and '3'; skip '2' and '4'
        for (final name in ['1', '3']) {
          final d = Directory('${comicDir.path}/$name');
          await d.create();
          await File('${d.path}/1.jpg').writeAsBytes([1]);
        }
        final comic = _groupedComic();

        final result = CBZ.collectAvailableChaptersForTesting(comic, const [
          '1',
          '2',
          '3',
          '4',
        ]);

        expect(result, ['1', '3']);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('returns empty when all dirs missing', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        LocalManager().path = tmpRoot.path;
        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        final comic = _groupedComic();

        final result = CBZ.collectAvailableChaptersForTesting(comic, const [
          '1',
          '2',
        ]);

        expect(result, isEmpty);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });
  });

  group('exportByChapters', () {
    // The native zip_flutter dynamic library cannot be loaded in flutter_test,
    // so swap in a stub compressor that just materializes the destination file.
    final realCompressor = CBZ.compressor;
    setUp(() {
      CBZ.compressor = (src, dst) async {
        await File(dst).writeAsBytes([0]);
      };
    });

    tearDown(() {
      CBZ.compressor = realCompressor;
    });

    test('produces one CBZ per available chapter', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        App.cachePath = '${tmpRoot.path}/cache';
        await Directory(App.cachePath).create(recursive: true);
        LocalManager().path = tmpRoot.path;
        final outDir = '${tmpRoot.path}/out';
        await Directory(outDir).create(recursive: true);

        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
        for (final name in ['1', '2', '3', '4', '5', '6']) {
          final d = Directory('${comicDir.path}/$name');
          await d.create();
          await File('${d.path}/1.jpg').writeAsBytes([1, 2, 3]);
          await File('${d.path}/2.jpg').writeAsBytes([4, 5, 6]);
        }
        final comic = _groupedComic();

        final result = await CBZ.exportByChapters(comic, outDir);

        expect(result.files, hasLength(6));
        expect(result.errors, isEmpty);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('skips chapters with missing dirs', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        App.cachePath = '${tmpRoot.path}/cache';
        await Directory(App.cachePath).create(recursive: true);
        LocalManager().path = tmpRoot.path;
        final outDir = '${tmpRoot.path}/out';
        await Directory(outDir).create(recursive: true);

        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
        // Only create dirs for chapters 1,2,4,5,6; skip 3
        for (final name in ['1', '2', '4', '5', '6']) {
          final d = Directory('${comicDir.path}/$name');
          await d.create();
          await File('${d.path}/1.jpg').writeAsBytes([1]);
        }
        final comic = _groupedComic();

        final result = await CBZ.exportByChapters(comic, outDir);

        expect(result.files, hasLength(5));
        expect(result.errors, isEmpty);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('throws StateError when no chapters on disk', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        App.cachePath = '${tmpRoot.path}/cache';
        await Directory(App.cachePath).create(recursive: true);
        LocalManager().path = tmpRoot.path;
        final outDir = '${tmpRoot.path}/out';
        await Directory(outDir).create(recursive: true);
        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        final comic = _groupedComic(downloadedChapters: const []);

        expect(() => CBZ.exportByChapters(comic, outDir), throwsStateError);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('throws StateError for chapterless comic', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        final outDir = '${tmpRoot.path}/out';
        await Directory(outDir).create(recursive: true);
        final comic = LocalComic(
          id: 'flat',
          title: 'Flat',
          subtitle: '',
          tags: const [],
          directory: 'flat-dir',
          chapters: null,
          cover: 'cover.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        );

        expect(() => CBZ.exportByChapters(comic, outDir), throwsStateError);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('stops at cancellation before next chapter', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        App.cachePath = '${tmpRoot.path}/cache';
        await Directory(App.cachePath).create(recursive: true);
        LocalManager().path = tmpRoot.path;
        final outDir = '${tmpRoot.path}/out';
        await Directory(outDir).create(recursive: true);
        final comicDir = Directory('${tmpRoot.path}/grouped-dir');
        await comicDir.create(recursive: true);
        await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
        for (final name in ['1', '2', '3', '4', '5', '6']) {
          final d = Directory('${comicDir.path}/$name');
          await d.create();
          await File('${d.path}/1.jpg').writeAsBytes([1]);
        }
        final comic = _groupedComic();

        var cancelled = false;
        final result = await CBZ.exportByChapters(
          comic,
          outDir,
          isCancelled: () => cancelled,
          onProgress: (completed, total, label) {
            if (completed >= 1) cancelled = true;
          },
        );

        expect(result.files.length, lessThanOrEqualTo(2));
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('works for flat (non-grouped) chaptered comic', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('cbz_test_');
      try {
        App.dataPath = tmpRoot.path;
        App.cachePath = '${tmpRoot.path}/cache';
        await Directory(App.cachePath).create(recursive: true);
        LocalManager().path = tmpRoot.path;
        final outDir = '${tmpRoot.path}/out';
        await Directory(outDir).create(recursive: true);

        final comicDir = Directory('${tmpRoot.path}/flat-dir');
        await comicDir.create(recursive: true);
        await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
        for (final name in ['1', '2', '3']) {
          final d = Directory('${comicDir.path}/$name');
          await d.create();
          await File('${d.path}/1.jpg').writeAsBytes([1]);
        }
        final comic = LocalComic(
          id: 'flat-id',
          title: 'Flat Comic',
          subtitle: 'Author',
          tags: const ['tag'],
          directory: 'flat-dir',
          chapters: const ComicChapters({'1': '001', '2': '002', '3': '003'}),
          cover: 'cover.jpg',
          comicType: ComicType.local,
          downloadedChapters: const ['1', '2', '3'],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        );

        final result = await CBZ.exportByChapters(comic, outDir);

        expect(result.files, hasLength(3));
        expect(result.errors, isEmpty);
      } finally {
        await tmpRoot.delete(recursive: true);
      }
    });
  });
}
