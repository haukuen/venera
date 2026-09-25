import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/explore_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/pages/settings/settings_page.dart';

import 'support/app_test_harness.dart';

/// Pages that can be built without a live comic source or a loaded comic.
/// Each is rendered under every layout case; any RenderFlex overflow or
/// malformed semantics node fails the test.
final _pages = <String, Widget Function()>{
  'AggregatedSearchPage': () => const AggregatedSearchPage(keyword: 'test'),
  'CategoriesPage': () => const CategoriesPage(),
  'CategoryComicsPage': () =>
      const CategoryComicsPage(category: 'test', categoryKey: 'test'),
  'ComicSourcePage': () => const ComicSourcePage(),
  'DownloadingPage': () => const DownloadingPage(),
  'ExplorePage': () => const ExplorePage(),
  'FavoritesPage': () => const FavoritesPage(),
  'FollowUpdatesPage': () => const FollowUpdatesPage(),
  'HistoryPage': () => const HistoryPage(),
  'HomePage': () => const HomePage(),
  'LocalComicsPage': () => const LocalComicsPage(),
  'RankingPage': () => const RankingPage(categoryKey: 'test'),
  'SearchPage': () => const SearchPage(),
  'SearchResultPage': () =>
      const SearchResultPage(text: 'test', sourceKey: 'test'),
  'SettingsPage': () => const SettingsPage(),
  'AboutSettings': () => const AboutSettings(),
  'AppearanceSettings': () => const AppearanceSettings(),
  'LocalFavoritesSettings': () => const LocalFavoritesSettings(),
  'ReaderSettings': () => const ReaderSettings(),
  'UpdatesSettings': () => const UpdatesSettings(),
};

/// Pages that read the comic source list, which lives behind
/// ComicSourceManager -> JsEngine (a background isolate). The test VM cannot
/// boot that isolate, so these stay in the matrix but are marked skipped:
/// un-skip them once the JS engine can be driven headlessly.
const _needsComicSources = <String>{
  'CategoryComicsPage',
  'ExplorePage',
  'HomePage',
  'LocalComicsPage',
  'RankingPage',
  'SearchResultPage',
  'SettingsPage',
};

/// Pages that leave a long-lived timer running, which trips the framework's
/// "timer is still pending" invariant when run in sequence. Not a layout
/// defect (they render cleanly in isolation).
const _flakyTimer = <String>{'AggregatedSearchPage'};

const _comicSourceReason =
    'requires ComicSourceManager / JsEngine isolate, unavailable in flutter test';
const _timerReason = 'leaves a pending timer; fails when run in sequence';

String? _skipReasonFor(String page) {
  if (_needsComicSources.contains(page)) return _comicSourceReason;
  if (_flakyTimer.contains(page)) return _timerReason;
  return null;
}

void main() {
  setUpAll(() async {
    await initAppForTest();
  });

  for (final entry in _pages.entries) {
    final reason = _skipReasonFor(entry.key);
    for (final config in layoutCases) {
      final name = reason == null
          ? '${entry.key} lays out on ${config.name}'
          : '${entry.key} lays out on ${config.name} [$reason]';
      testWidgets(name, (tester) async {
        final error = await renderPage(tester, entry.value(), config: config);
        expect(
          error,
          isNull,
          reason:
              '${entry.key} threw while rendering at ${config.name}: $error',
        );
      }, skip: reason != null);
    }
  }
}
