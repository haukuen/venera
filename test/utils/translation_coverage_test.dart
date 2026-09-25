import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, Map<String, String>> loadTranslations() {
  final raw = Map<String, dynamic>.from(
    jsonDecode(File('assets/translation.json').readAsStringSync()),
  );
  final result = <String, Map<String, String>>{};
  for (final entry in raw.entries) {
    result[entry.key] = Map<String, String>.from(entry.value as Map);
  }
  return result;
}

void main() {
  final translations = loadTranslations();

  test('zh_CN and zh_TW cover the exact same set of keys', () {
    final cn = translations['zh_CN']!.keys.toSet();
    final tw = translations['zh_TW']!.keys.toSet();
    expect(
      cn.difference(tw),
      isEmpty,
      reason: 'keys missing from zh_TW: ${cn.difference(tw)}',
    );
    expect(
      tw.difference(cn),
      isEmpty,
      reason: 'keys missing from zh_CN: ${tw.difference(cn)}',
    );
  });

  test('no translation entry is empty', () {
    for (final entry in translations.entries) {
      for (final pair in entry.value.entries) {
        expect(
          pair.value.trim(),
          isNotEmpty,
          reason: '${entry.key}["${pair.key}"] is empty',
        );
      }
    }
  });

  test('UI-refactor user-facing strings are translated', () {
    const keys = [
      'UI font scale',
      'Appearance',
      'Theme',
      'Theme Mode',
      'Theme Color',
      'Display mode of comic tile',
      'Size of comic tile',
      'Display mode of comic list',
      'Cancel',
      'Confirm',
      'Export logs',
      'Error',
    ];
    for (final locale in ['zh_CN', 'zh_TW']) {
      final map = translations[locale]!;
      for (final key in keys) {
        expect(map, contains(key), reason: '$locale missing "$key"');
      }
    }
  });
}
