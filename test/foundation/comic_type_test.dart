import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';

void main() {
  test('local type maps to "local" source key', () {
    expect(ComicType.local.sourceKey, 'local');
    expect(ComicType.local.comicSource, isNull);
  });

  test(
    'missing comic source falls back to "Unknown:" key instead of crashing',
    () {
      final type = ComicType.fromKey('no-such-source');
      expect(type.comicSource, isNull);
      expect(type.sourceKey, 'Unknown:${type.value}');
    },
  );

  test('fallback key matches History.sourceKey fallback semantics', () {
    final type = ComicType.fromKey('no-such-source');
    expect(type.sourceKey, 'Unknown:${type.value}');
  });
}
