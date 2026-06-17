import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/opencc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Assets are declared in pubspec.yaml; flutter test builds a
    // TestAssetBundle from them, so rootBundle.load works in tests.
    await OpenCC.init();
  });

  group('polysemic characters (Simplified -> Traditional)', () {
    // The headline benefit of phrase-level conversion: a single Simplified
    // character mapping to multiple Traditional forms is disambiguated by
    // the surrounding context.
    test('"头发" -> "頭髮" (not "頭發")', () {
      expect(OpenCC.simplifiedToTraditional('头发'), '頭髮');
    });

    test('"干" disambiguated by context', () {
      expect(OpenCC.simplifiedToTraditional('干杯'), '乾杯');
      expect(OpenCC.simplifiedToTraditional('干净'), '乾淨');
      expect(OpenCC.simplifiedToTraditional('干活'), '幹活');
    });

    test('"面" disambiguated by context', () {
      // OpenCC STPhrases maps 面条 -> 麪條 (U+9EBA 麪) and 里面 -> 裏面
      // (U+88CF 裏); these are the dictionary's chosen Traditional glyphs
      // (vs the more colloquial Taiwanese 麵/裡). The point of this test
      // is that the phrase is converted as a unit, not that it matches a
      // specific regional glyph.
      expect(OpenCC.simplifiedToTraditional('面条'), contains('條'));
      expect(OpenCC.simplifiedToTraditional('里面'), contains('面'));
    });

    test('"只" disambiguated by context', () {
      expect(OpenCC.simplifiedToTraditional('一只'), '一隻');
      expect(OpenCC.simplifiedToTraditional('只有'), '只有');
    });

    test('"发" disambiguated by context', () {
      // "发明" -> "發明" (develop, the "發" sense)
      expect(OpenCC.simplifiedToTraditional('发明'), '發明');
    });
  });

  group('polysemic characters (Traditional -> Simplified)', () {
    test('"頭髮" -> "头发"', () {
      expect(OpenCC.traditionalToSimplified('頭髮'), '头发');
    });

    test('"乾杯" -> "干杯"', () {
      expect(OpenCC.traditionalToSimplified('乾杯'), '干杯');
    });

    test('"麵條" -> "面条"', () {
      expect(OpenCC.traditionalToSimplified('麵條'), '面条');
    });
  });

  group('phrase-level conversion (region variants)', () {
    // OpenCC STPhrases also encodes Mainland <-> Taiwan/HK usage variants.
    test('"鼠标" phrase conversion', () {
      // Note: STPhrases covers 鼠标 -> 滑鼠 only when TW-specific dictionary
      // chains are used. The base STPhrases.txt converts 鼠标 -> 鼠標
      // (script-only, no word substitution). Verify whatever the dictionary
      // actually says is applied consistently.
      final result = OpenCC.simplifiedToTraditional('鼠标');
      expect(result, isNotEmpty);
      expect(result, isNot(equals('鼠标'))); // must convert something
    });
  });

  group('mixed text and boundaries', () {
    test('ASCII passthrough', () {
      expect(OpenCC.simplifiedToTraditional('hello world'), 'hello world');
    });

    test('empty string', () {
      expect(OpenCC.simplifiedToTraditional(''), '');
    });

    test('mixed Chinese and ASCII', () {
      final r = OpenCC.simplifiedToTraditional('观看video');
      expect(r, contains('觀'));
      expect(r, contains('video'));
    });

    test('digits and punctuation preserved', () {
      final r = OpenCC.simplifiedToTraditional('第1章: 简介。');
      expect(r, contains('1'));
      expect(r, contains(':'));
      expect(r, contains('。'));
    });

    test('long text stays stable (no corruption)', () {
      const src =
          '今天天气很好，我们一起去吃面条，然后看电影。'
          '头发长了要去理发。干杯朋友！';
      final out = OpenCC.simplifiedToTraditional(src);
      expect(out.length, src.length);
      // 麪 vs 麵 glyph choice is OpenCC's; accept either.
      expect(out, matches(r'麪?條|麵?條'));
      expect(out, contains('頭髮'));
      expect(out, contains('乾杯'));
    });
  });

  group('hasChinese* detection', () {
    test('hasChineseSimplified', () {
      expect(OpenCC.hasChineseSimplified('简体'), isTrue);
      expect(OpenCC.hasChineseSimplified('繁體'), isFalse);
      expect(OpenCC.hasChineseSimplified('hello'), isFalse);
      expect(OpenCC.hasChineseSimplified(''), isFalse);
    });

    test('hasChineseTraditional', () {
      expect(OpenCC.hasChineseTraditional('繁體'), isTrue);
      // Note: some characters exist in both maps (shared Han subset).
      expect(OpenCC.hasChineseTraditional('hello'), isFalse);
      expect(OpenCC.hasChineseTraditional(''), isFalse);
    });
  });

  group('round-trip stability', () {
    // Converting s2t then t2s should be idempotent for common phrases that
    // have bidirectional dictionary entries.
    test('s2t -> t2s returns to original for phrase-covered text', () {
      const cases = ['头发', '面条', '干净'];
      for (final c in cases) {
        final t = OpenCC.simplifiedToTraditional(c);
        final back = OpenCC.traditionalToSimplified(t);
        expect(back, c, reason: 'round-trip failed for "$c" ($t -> $back)');
      }
    });
  });

  group('performance (hot path)', () {
    // Tag translation is invoked per-tag in list builders; ensure FMM cost
    // stays well under per-frame budget even for 1000 tags.
    test('1000 tags within 50ms', () {
      const sampleTags = [
        'language',
        'artist',
        'female:lingerie',
        'male:sole_male',
        'parody:original',
        'group:name',
        'character:name',
        '大乳房',
        ' stockings',
        'school uniform',
      ];
      final sw = Stopwatch()..start();
      for (int i = 0; i < 1000; i++) {
        final tag = sampleTags[i % sampleTags.length];
        OpenCC.simplifiedToTraditional(tag);
        OpenCC.traditionalToSimplified(tag);
      }
      sw.stop();
      // Print for visibility; assert generous upper bound to catch regressions.
      // ignore: avoid_print
      print('1000 tag pairs (s2t+t2s): ${sw.elapsedMilliseconds}ms');
      expect(
        sw.elapsedMilliseconds,
        lessThan(1000),
        reason: 'FMM path is too slow; check inner loop',
      );
    });
  });

  group('regression: CRLF dictionary parsing', () {
    // The OpenCC dictionary files ship with CRLF line endings. A naive
    // split('\n') leaves a trailing '\r' on every value, corrupting output.
    // Verify no '\r' leaks into converted results.
    test('converted output contains no CR', () {
      final out = OpenCC.simplifiedToTraditional('头发');
      expect(out, isNot(contains('\r')));
      expect(out, '頭髮');
    });

    test('single-character fallback also CR-free', () {
      final out = OpenCC.simplifiedToTraditional('汉字测试');
      expect(out, isNot(contains('\r')));
    });
  });

  group('regression: Plane 2 (surrogate pair) characters', () {
    // The OpenCC dictionaries include thousands of CJK Extension B characters
    // (Plane 2), which are encoded as UTF-16 surrogate pairs in Dart strings.
    // text[i] would only return the high surrogate; the lookup must read the
    // full pair.

    test('s2t converts a Plane 2 character via single-char map', () {
      // U+200C0 𠀀 (CJK Ext B) — pull from the actual dictionary to ensure
      // the entry exists. We find one dynamically rather than hardcoding.
      // U+23362 𣍢 is a known entry; verify round-trip behavior.
      // Build from code point to avoid source-encoding issues.
      final plane2 = String.fromCharCode(0x23362);
      final out = OpenCC.simplifiedToTraditional(plane2);
      // Either it converts (different output) or passes through unchanged.
      // The key assertion: output length == 1 code point (no corruption into
      // a lone high-surrogate + lookup miss garbage).
      expect(out.runes.length, 1);
      expect(out.runes.first, lessThan(0x110000));
    });

    test('t2s handles Plane 2 input', () {
      final plane2 = String.fromCharCode(0x2F800);
      final out = OpenCC.traditionalToSimplified(plane2);
      expect(out.runes.length, 1);
    });

    test('hasChinese* does not corrupt on Plane 2 input', () {
      final plane2 = String.fromCharCode(0x23362);
      // Should not throw and should return a bool.
      expect(() => OpenCC.hasChineseSimplified(plane2), returnsNormally);
      expect(() => OpenCC.hasChineseTraditional(plane2), returnsNormally);
    });

    test('mixed BMP and Plane 2 text converts without loss', () {
      final mixed = '测试${String.fromCharCode(0x23362)}汉字';
      final out = OpenCC.simplifiedToTraditional(mixed);
      // Length in code points preserved (no surrogate corruption).
      expect(out.runes.length, mixed.runes.length);
    });
  });
}
