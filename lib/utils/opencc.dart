import 'dart:convert';

import 'package:flutter/services.dart';

/// Chinese conversion between Simplified and Traditional Chinese.
///
/// Uses OpenCC dictionary with Forward Maximum Matching (FMM) algorithm.
/// Phrase-level conversion disambiguates polysemic characters such as
/// "头发" -> "頭髮" (not "頭發") by matching multi-character phrases first
/// before falling back to single-character mapping.
///
/// Dictionary source: https://github.com/BYVoid/OpenCC (Apache-2.0)
abstract class OpenCC {
  static late final Map<String, String> _s2tChars;
  static late final Map<String, String> _s2tPhrases;
  static late final Map<String, String> _t2sChars;
  static late final Map<String, String> _t2sPhrases;

  /// Maximum phrase length (in code units) in OpenCC dictionaries.
  /// Empirically the longest key is 12 chars; clamp to 8 to bound FMM
  /// inner-loop cost (longer entries are rare proverbs with negligible hit
  /// rate, and substring construction cost scales with length).
  static const int _maxPhraseLen = 8;

  static Future<void> init() async {
    final futures = await Future.wait([
      _loadDict("assets/opencc/STCharacters.txt"),
      _loadDict("assets/opencc/STPhrases.txt"),
      _loadDict("assets/opencc/TSCharacters.txt"),
      _loadDict("assets/opencc/TSPhrases.txt"),
    ]);
    _s2tChars = futures[0];
    _s2tPhrases = futures[1];
    _t2sChars = futures[2];
    _t2sPhrases = futures[3];
  }

  /// Loads an OpenCC txt dictionary.
  ///
  /// Format: `key\tvalue` per line. `value` may contain space-separated
  /// alternatives (e.g. "只\t隻 只"); the first alternative is used.
  /// Lines starting with '#' or empty are skipped.
  ///
  /// Uses [LineSplitter] instead of `split('\n')` so that CRLF, LF, and CR
  /// line endings are all handled without leaving a trailing `\r` on the
  /// value (the OpenCC dictionary files ship as CRLF).
  static Future<Map<String, String>> _loadDict(String asset) async {
    final data = await rootBundle.load(asset);
    final text = utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final map = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      var value = line.substring(tab + 1);
      final space = value.indexOf(' ');
      if (space >= 0) {
        value = value.substring(0, space);
      }
      if (value.isEmpty) continue;
      map[key] = value;
    }
    return map;
  }

  /// Returns true if [text] contains any character that has a
  /// Simplified-to-Traditional mapping (i.e. a "simplified" character).
  ///
  /// Iterates UTF-16 code units but reads full surrogate pairs as a single
  /// key, since the OpenCC dictionaries contain Plane 2 characters (rare
  /// Han extensions) which are encoded as surrogate pairs in Dart strings.
  static bool hasChineseSimplified(String text) {
    for (int i = 0; i < text.length; i++) {
      final ch = _charAt(text, i);
      if (_s2tChars.containsKey(ch)) return true;
      if (ch.length == 2) i++; // skip low surrogate
    }
    return false;
  }

  /// Returns true if [text] contains any character that has a
  /// Traditional-to-Simplified mapping (i.e. a "traditional" character).
  /// See [hasChineseSimplified] for surrogate-pair handling.
  static bool hasChineseTraditional(String text) {
    for (int i = 0; i < text.length; i++) {
      final ch = _charAt(text, i);
      if (_t2sChars.containsKey(ch)) return true;
      if (ch.length == 2) i++; // skip low surrogate
    }
    return false;
  }

  /// Converts Simplified Chinese to Traditional Chinese.
  static String simplifiedToTraditional(String text) {
    return _fmm(text, _s2tChars, _s2tPhrases);
  }

  /// Converts Traditional Chinese to Simplified Chinese.
  static String traditionalToSimplified(String text) {
    return _fmm(text, _t2sChars, _t2sPhrases);
  }

  /// Reads one full character starting at [i].
  ///
  /// Returns a 2-char string if [i] is a high surrogate followed by a low
  /// surrogate (a Plane 2 character such as those in CJK Extension B),
  /// otherwise a 1-char string. Used to look up OpenCC dictionaries which
  /// store keys as full characters including surrogate pairs.
  static String _charAt(String text, int i) {
    final cu = text.codeUnitAt(i);
    const hiStart = 0xD800, hiEnd = 0xDBFF;
    const loStart = 0xDC00, loEnd = 0xDFFF;
    if (cu >= hiStart && cu <= hiEnd && i + 1 < text.length) {
      final lo = text.codeUnitAt(i + 1);
      if (lo >= loStart && lo <= loEnd) {
        return text.substring(i, i + 2);
      }
    }
    return text.substring(i, i + 1);
  }

  /// Forward Maximum Matching conversion.
  ///
  /// Scans [text] left-to-right. At each position tries the longest phrase
  /// (up to [_maxPhraseLen] chars) present in [phrases]; on miss falls back
  /// to the single-character map [chars], or the original char. Surrogate
  /// pairs are treated as a single character in the fallback branch.
  static String _fmm(
    String text,
    Map<String, String> chars,
    Map<String, String> phrases,
  ) {
    if (text.isEmpty) return text;
    final sb = StringBuffer();
    int i = 0;
    final n = text.length;
    while (i < n) {
      String? matched;
      int matchedLen = 0;
      final maxLen = (n - i < _maxPhraseLen) ? (n - i) : _maxPhraseLen;
      // Try longest first; phrase table requires length >= 2.
      for (int len = maxLen; len >= 2; len--) {
        final candidate = text.substring(i, i + len);
        final v = phrases[candidate];
        if (v != null) {
          matched = v;
          matchedLen = len;
          break;
        }
      }
      if (matched != null) {
        sb.write(matched);
        i += matchedLen;
      } else {
        final ch = _charAt(text, i);
        sb.write(chars[ch] ?? ch);
        i += ch.length;
      }
    }
    return sb.toString();
  }
}
