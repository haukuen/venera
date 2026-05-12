import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/comic_export.dart';

void main() {
  group('ComicExportInfo', () {
    test('toJson should return correct map', () {
      final info = ComicExportInfo(
        id: '123',
        title: 'Test Comic',
        subtitle: 'Author',
        tags: ['tag1', 'tag2'],
        directory: 'test_comic',
        chapters: {'ch1': 'Chapter 1', 'ch2': 'Chapter 2'},
        cover: 'cover.jpg',
        comicType: 12345,
        downloadedChapters: ['ch1', 'ch2'],
        createdAt: 1704067200000,
        sourceDirectory: '123_12345',
      );

      final json = info.toJson();
      expect(json['id'], '123');
      expect(json['title'], 'Test Comic');
      expect(json['subtitle'], 'Author');
      expect(json['tags'], ['tag1', 'tag2']);
      expect(json['directory'], 'test_comic');
      expect(json['chapters'], {'ch1': 'Chapter 1', 'ch2': 'Chapter 2'});
      expect(json['cover'], 'cover.jpg');
      expect(json['comicType'], 12345);
      expect(json['downloadedChapters'], ['ch1', 'ch2']);
      expect(json['createdAt'], 1704067200000);
      expect(json['sourceDirectory'], '123_12345');
    });

    test('toJson should handle empty lists and maps', () {
      final info = ComicExportInfo(
        id: '456',
        title: 'Empty Comic',
        subtitle: '',
        tags: [],
        directory: 'empty_comic',
        chapters: {},
        cover: '',
        comicType: 0,
        downloadedChapters: [],
        createdAt: 0,
        sourceDirectory: '456_0',
      );

      final json = info.toJson();
      expect(json['tags'], isEmpty);
      expect(json['chapters'], isEmpty);
      expect(json['downloadedChapters'], isEmpty);
    });
  });

  group('ComicExportMetadata', () {
    test('toJson should return correct structure', () {
      final metadata = ComicExportMetadata(
        version: 1,
        exportTime: '2026-05-12T00:00:00Z',
        totalCount: 1,
        comics: [
          ComicExportInfo(
            id: '123',
            title: 'Test Comic',
            subtitle: 'Author',
            tags: [],
            directory: 'test_comic',
            chapters: {},
            cover: 'cover.jpg',
            comicType: 12345,
            downloadedChapters: [],
            createdAt: 1704067200000,
            sourceDirectory: '123_12345',
          ),
        ],
      );

      final json = metadata.toJson();
      expect(json['version'], 1);
      expect(json['exportTime'], '2026-05-12T00:00:00Z');
      expect(json['totalCount'], 1);
      expect(json['comics'], isA<List>());
      expect((json['comics'] as List).length, 1);
    });

    test('toJson should serialize comics list correctly', () {
      final metadata = ComicExportMetadata(
        version: 2,
        exportTime: '2026-01-01T12:00:00Z',
        totalCount: 2,
        comics: [
          ComicExportInfo(
            id: '1',
            title: 'Comic 1',
            subtitle: 'Sub1',
            tags: ['action'],
            directory: 'comic1',
            chapters: {'c1': 'Ch 1'},
            cover: 'c1.jpg',
            comicType: 100,
            downloadedChapters: ['c1'],
            createdAt: 1000000,
            sourceDirectory: '1_100',
          ),
          ComicExportInfo(
            id: '2',
            title: 'Comic 2',
            subtitle: 'Sub2',
            tags: ['romance'],
            directory: 'comic2',
            chapters: {'c2': 'Ch 2'},
            cover: 'c2.jpg',
            comicType: 200,
            downloadedChapters: ['c2'],
            createdAt: 2000000,
            sourceDirectory: '2_200',
          ),
        ],
      );

      final json = metadata.toJson();
      expect(json['version'], 2);
      expect(json['totalCount'], 2);

      final comicsList = json['comics'] as List;
      expect(comicsList.length, 2);

      final firstComic = comicsList[0] as Map<String, dynamic>;
      expect(firstComic['id'], '1');
      expect(firstComic['title'], 'Comic 1');
      expect(firstComic['tags'], ['action']);

      final secondComic = comicsList[1] as Map<String, dynamic>;
      expect(secondComic['id'], '2');
      expect(secondComic['title'], 'Comic 2');
      expect(secondComic['tags'], ['romance']);
    });

    test('toJson should handle empty comics list', () {
      final metadata = ComicExportMetadata(
        version: 1,
        exportTime: '2026-05-12T00:00:00Z',
        totalCount: 0,
        comics: [],
      );

      final json = metadata.toJson();
      expect(json['version'], 1);
      expect(json['totalCount'], 0);
      expect(json['comics'], isEmpty);
    });
  });
}
