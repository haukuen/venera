import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/read_later.dart';

void main() {
  test('read later item equality survives list refreshes', () {
    final original = ReadLaterItem(
      id: 'comic-1',
      type: ComicType.fromKey('test-source'),
      title: 'Original title',
      subtitle: 'Original subtitle',
      cover: 'cover-a',
      sourceKey: 'test-source',
      addedTime: DateTime.fromMillisecondsSinceEpoch(1),
    );
    final refreshed = ReadLaterItem(
      id: 'comic-1',
      type: ComicType.fromKey('test-source'),
      title: 'Updated title',
      subtitle: 'Updated subtitle',
      cover: 'cover-b',
      sourceKey: 'test-source',
      addedTime: DateTime.fromMillisecondsSinceEpoch(2),
    );

    final selectedComics = <ReadLaterItem, bool>{original: true};
    final refreshedComics = <ReadLaterItem>[refreshed];

    selectedComics.removeWhere((comic, _) => !refreshedComics.contains(comic));

    expect(selectedComics, containsPair(original, true));
    expect(selectedComics.containsKey(refreshed), isTrue);
  });
}
