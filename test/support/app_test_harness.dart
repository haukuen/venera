import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_theme.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';

import 'package:venera/foundation/read_later.dart';
import 'package:venera/utils/translations.dart';

/// Routes every path_provider lookup at a throwaway temp directory so pages
/// that persist state can initialise inside the test VM.
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getTemporaryPath() async => dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getApplicationCachePath() async => dir;

  @override
  Future<String?> getLibraryPath() async => dir;

  @override
  Future<String?> getExternalStoragePath() async => dir;

  @override
  Future<String?> getDownloadsPath() async => dir;
}

bool _initialised = false;

/// Brings up the minimum set of app state pages need to build: translations,
/// a data directory, and the SQLite-backed managers. Safe to call repeatedly.
Future<void> initAppForTest() async {
  if (_initialised) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  await AppTranslation.init();
  final dir = Directory.systemTemp.createTempSync('venera_layout_test');
  PathProviderPlatform.instance = _TempPathProvider(dir.path);
  App.dataPath = dir.path;
  App.cachePath = dir.path;
  App.version = '0.0.0-test';
  // Manager inits await appdata.ensureInit(), which only completes once
  // doInit() has run (normally App.init() does this). Drive it directly.
  await appdata.init();
  // Several pages read these as non-null lists; their shipped default is null.
  appdata.settings['searchSources'] = <String>[];
  appdata.settings['quickFavorite'] = 'No';
  await HistoryManager().init();
  await LocalFavoritesManager().init();
  // LocalManager().init() is skipped: it awaits ComicSourceManager, which
  // spins up the JS engine isolate and cannot run in the test VM.
  await ReadLaterManager().init();
  _initialised = true;
}

/// A window/text configuration to render a page under.
class LayoutCase {
  const LayoutCase(this.name, this.size, this.textScale, {this.dark = false});

  final String name;
  final Size size;
  final double textScale;
  final bool dark;

  @override
  String toString() => name;
}

/// The configurations that actually catch layout defects: a narrow phone, the
/// same phone at the maximum supported font scale, and a wide desktop window
/// also at maximum scale.
const layoutCases = <LayoutCase>[
  LayoutCase('phone', Size(400, 800), 1.0),
  LayoutCase('phone@1.3', Size(400, 800), 1.3),
  LayoutCase('desktop@1.3', Size(1400, 900), 1.3, dark: true),
];

/// Renders [page] inside the real app theme with the semantics tree enabled,
/// so both RenderFlex overflows and invalid SemanticsNode configurations
/// surface as test failures instead of only appearing at runtime.
///
/// Returns any exception captured while rendering; `null` means the page laid
/// out cleanly.
Future<Object?> renderPage(
  WidgetTester tester,
  Widget page, {
  required LayoutCase config,
}) async {
  tester.view.physicalSize = config.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final handle = tester.ensureSemantics();

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(
        primary: Colors.blue,
        secondary: Colors.green,
        tertiary: Colors.orange,
        brightness: config.dark ? Brightness.dark : Brightness.light,
      ),
      darkTheme: AppTheme.build(
        primary: Colors.blue,
        secondary: Colors.green,
        tertiary: Colors.orange,
        brightness: Brightness.dark,
      ),
      themeMode: config.dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(textScaler: TextScaler.linear(config.textScale)),
          child: child!,
        );
      },
      home: Scaffold(body: page),
    ),
  );
  // Let async state settle; pages that load data render a placeholder first.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final error = tester.takeException();
  // Tear the tree down so any debounce/delayed work the page started is
  // cancelled; the framework fails a test that leaves a timer pending, and an
  // undrained timer from one case can surface in the next.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
  // Dispose before the test framework's end-of-test semantics check runs;
  // addTearDown would run too late.
  handle.dispose();
  return error;
}
