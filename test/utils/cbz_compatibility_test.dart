import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/cbz.dart';

void main() {
  group('CBZ compatibility helpers', () {
    test(
      'compatiblePageFileName pads to four digits and preserves extension',
      () {
        expect(CBZ.compatiblePageFileName(1, 'jpg'), '0001.jpg');
      },
    );

    test(
      'buildComicInfoXmlForTesting includes page metadata without cover',
      () {
        final xml = CBZ.buildComicInfoXmlForTesting(
          ComicMetaData(
            title: 'Title & <Story>',
            author: 'Author "A" & Co',
            tags: ['tag <one>', 'tag & two'],
          ),
          pageCount: 3,
        );

        expect(xml, contains('<Title>Title &amp; &lt;Story&gt;</Title>'));
        expect(xml, contains('<Writer>Author &quot;A&quot; &amp; Co</Writer>'));
        expect(xml, contains('<Tags>tag &lt;one&gt;, tag &amp; two</Tags>'));
        expect(xml, isNot(contains('<Genre>')));
        expect(xml, isNot(contains('<Number>')));
        expect(xml, contains('<PageCount>3</PageCount>'));
        expect(xml, contains('<Manga>Unknown</Manga>'));
        expect(xml, contains('<BlackAndWhite>Unknown</BlackAndWhite>'));
        expect(xml, contains('<Page Image="0" Type="Story" />'));
        expect(xml, contains('<Page Image="1" Type="Story" />'));
        expect(xml, contains('<Page Image="2" Type="Story" />'));
        expect(xml, isNot(contains('Type="FrontCover"')));
      },
    );

    test('single-chapter ComicInfo writes chapter title and number', () {
      final xml = CBZ.buildComicInfoXmlForTesting(
        ComicMetaData(
          title: '测试漫画',
          author: '',
          tags: [],
          chapters: [ComicChapter(title: '间章 2026-05-31', start: 1, end: 20)],
        ),
        pageCount: 20,
        titleOverride: '间章 2026-05-31',
        chapterNumber: 3,
      );

      // Kavita reads Title as the per-chapter display name.
      expect(xml, contains('<Title>间章 2026-05-31</Title>'));
      expect(xml, contains('<Series>测试漫画</Series>'));
      expect(xml, contains('<Number>3</Number>'));
    });

    test('chapter number supports decimals like 2.5', () {
      final xml = CBZ.buildComicInfoXmlForTesting(
        ComicMetaData(title: 'Comic', author: '', tags: []),
        pageCount: 1,
        titleOverride: 'Extra',
        chapterNumber: 2.5,
      );

      expect(xml, contains('<Number>2.5</Number>'));
    });

    test('multi-chapter ComicInfo keeps comic title and Notes map', () {
      final xml = CBZ.buildComicInfoXmlForTesting(
        ComicMetaData(
          title: 'Comic',
          author: '',
          tags: [],
          chapters: [
            ComicChapter(title: '第1话', start: 1, end: 2),
            ComicChapter(title: '第2话', start: 3, end: 5),
          ],
        ),
        pageCount: 5,
      );

      expect(xml, contains('<Title>Comic</Title>'));
      expect(xml, contains('<Series>Comic</Series>'));
      expect(xml, isNot(contains('<Number>')));
      expect(xml, contains('<Notes>Chapters: 第1话: 1-2; 第2话: 3-5</Notes>'));
    });

    test('buildChapterRangesForTesting calculates contiguous page ranges', () {
      final chapters = CBZ.buildChapterRangesForTesting({
        'Chapter 1': 2,
        'Chapter 2': 3,
      });

      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Chapter 1');
      expect(chapters[0].start, 1);
      expect(chapters[0].end, 2);
      expect(chapters[1].title, 'Chapter 2');
      expect(chapters[1].start, 3);
      expect(chapters[1].end, 5);
    });

    test('localFilePathFromImageUriForTesting strips file URI prefix', () {
      final result = CBZ.localFilePathFromImageUriForTesting(
        'file:///tmp/a.jpg',
      );

      expect(result.startsWith('file://'), isFalse);
      expect(result, contains('a.jpg'));
    });

    test(
      'localFilePathFromImageUriForTesting leaves plain paths unchanged',
      () {
        const plainPath = '/tmp/a.jpg';

        expect(CBZ.localFilePathFromImageUriForTesting(plainPath), plainPath);
      },
    );
  });
}
