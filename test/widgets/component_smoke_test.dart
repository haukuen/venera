import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/foundation/app_theme.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/translations.dart';

ThemeData buildTheme(Brightness brightness) {
  return AppTheme.build(
    primary: Colors.blue,
    secondary: Colors.green,
    tertiary: Colors.orange,
    brightness: brightness,
  );
}

Widget wrap(
  Widget child, {
  required Brightness brightness,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, widget) {
      if (textScale == 1.0 || widget == null) return widget!;
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: widget,
      );
    },
    home: Scaffold(
      body: Center(child: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  // Several components label themselves via `.tl`; load the real table so the
  // extension has a value (it falls back to the English source string).
  setUpAll(() async {
    await AppTranslation.init();
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    group('components in $brightness', () {
      testWidgets('Button renders every variant without overflow', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Button.filled(onPressed: () {}, child: const Text('Filled')),
                Button.outlined(
                  onPressed: () {},
                  child: const Text('Outlined'),
                ),
                Button.text(onPressed: () {}, child: const Text('Text')),
                Button.normal(onPressed: () {}, child: const Text('Normal')),
                Button.icon(icon: const Icon(Icons.add), onPressed: () {}),
                Button.filled(
                  isLoading: true,
                  onPressed: () {},
                  child: const Text('Loading'),
                ),
              ],
            ),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Filled'), findsOneWidget);
        expect(find.text('Outlined'), findsOneWidget);
        expect(find.text('Normal'), findsOneWidget);
      });

      testWidgets('Button invokes onPressed and keeps onPressedAt working', (
        tester,
      ) async {
        var taps = 0;
        Offset? at;
        await tester.pumpWidget(
          wrap(
            Button.filled(
              onPressed: () => taps++,
              onPressedAt: (offset) => at = offset,
              child: const Text('Tap me'),
            ),
            brightness: brightness,
          ),
        );
        await tester.tap(find.text('Tap me'));
        await tester.pump();
        expect(taps, 1);
        expect(at, isNotNull);
      });

      testWidgets('Appbar renders blur and shadow styles', (tester) async {
        await tester.pumpWidget(
          wrap(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Appbar(title: const Text('Blur'), style: AppbarStyle.blur),
                Appbar(title: const Text('Shadow'), style: AppbarStyle.shadow),
              ],
            ),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Blur'), findsOneWidget);
        expect(find.text('Shadow'), findsOneWidget);
      });

      testWidgets('ContentDialog renders title, content and two actions', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => ContentDialog(
                      title: 'Confirm',
                      content: const Text('Are you sure?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Confirm'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Are you sure?'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Confirm'), findsWidgets);
      });

      testWidgets('Select renders its current value', (tester) async {
        await tester.pumpWidget(
          wrap(
            Select(current: 'Light', values: ['Light', 'Dark']),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Light'), findsOneWidget);
      });

      testWidgets('PopoverSurface renders a child', (tester) async {
        await tester.pumpWidget(
          wrap(
            PopoverSurface(
              child: Text('Surface', textDirection: TextDirection.ltr),
            ),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Surface'), findsOneWidget);
      });
    });
  }

  testWidgets('CustomSlider builds a valid semantics node', (tester) async {
    // A node that advertises increase/decrease must declare its target value,
    // or Flutter throws while flushing the semantics tree. This also covers
    // the range ends, where the matching action has to be withheld.
    final handle = tester.ensureSemantics();
    var value = 4.0;
    late StateSetter setValue;
    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            setValue = setState;
            return CustomSlider(
              min: 0,
              max: 8,
              divisions: 8,
              value: value,
              focusNode: FocusNode(),
              onChanged: (v) => setState(() => value = v),
            );
          },
        ),
        brightness: Brightness.light,
      ),
    );
    expect(tester.takeException(), isNull);
    var node = tester.getSemantics(find.byType(CustomSlider));
    expect(node.flagsCollection.isSlider, isTrue);
    expect(node.value, '4');
    expect(node.increasedValue, '5');
    expect(node.decreasedValue, '3');
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);

    // At the top of the range there is no increase target: the node must
    // drop the action instead of carrying one with an empty target.
    setValue(() => value = 8.0);
    await tester.pump();
    expect(tester.takeException(), isNull);
    node = tester.getSemantics(find.byType(CustomSlider));
    expect(node.value, '8');
    // A missing target is stored as an empty string by SemanticsNode.
    expect(node.increasedValue, isEmpty);
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.increase),
      isFalse,
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);

    // Same at the bottom of the range.
    setValue(() => value = 0.0);
    await tester.pump();
    expect(tester.takeException(), isNull);
    node = tester.getSemantics(find.byType(CustomSlider));
    expect(node.value, '0');
    expect(node.decreasedValue, isEmpty);
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.decrease),
      isFalse,
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    handle.dispose();
  });

  testWidgets('CustomSlider stays compact enough for the reader toolbar', (
    tester,
  ) async {
    // The reader bottom bar is a fixed-height column; the slider must not
    // grow past its budget, even though its touch target is 48px.
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 105,
          child: Row(
            children: [
              Expanded(
                child: CustomSlider(
                  min: 0,
                  max: 8,
                  divisions: 8,
                  value: 4,
                  focusNode: FocusNode(),
                  onChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(CustomSlider)).height,
      lessThanOrEqualTo(56),
    );
  });

  testWidgets('showConfirmDialog offers an explicit cancel action', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showConfirmDialog(
              context: context,
              title: 'Delete',
              content: 'This cannot be undone.',
              onConfirm: () {},
            ),
            child: const Text('open'),
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);
  });

  group('core components survive the max UI font scale', () {
    testWidgets('Button, Appbar and dialog chrome do not overflow at 1.3', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Button.filled(
                onPressed: () {},
                child: const Text('A fairly long button label'),
              ),
              Button.outlined(
                onPressed: () {},
                child: const Text('Outlined label that is long'),
              ),
              Appbar(title: const Text('A long page title here')),
              ContentDialog(
                title: 'Dialog title',
                content: const Text('Some dialog body content.'),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Cancel')),
                  FilledButton(onPressed: () {}, child: const Text('Confirm')),
                ],
              ),
            ],
          ),
          brightness: Brightness.light,
          textScale: 1.3,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('theme roles must not override their surface color', () {
    testWidgets('toast text stays readable on the inverse surface', (
      tester,
    ) async {
      // Not wrapped in the scrolling harness: Overlay cannot size itself under
      // the unbounded height a SingleChildScrollView provides.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: OverlayWidget(
              Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showToast(
                      message: 'Saved successfully',
                      context: context,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      // Theme text roles carry their own onSurface color; the toast paints on
      // inverseSurface, so the text must re-assert onInverseSurface.
      final scheme = Theme.of(
        tester.element(find.text('Saved successfully')),
      ).colorScheme;
      final style = tester.widget<Text>(find.text('Saved successfully')).style;
      expect(style?.color, scheme.onInverseSurface);
      expect(style?.color, isNot(scheme.onSurface));
      // Fire the auto-dismiss timer so no timer is pending at test end.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('bottom navigation selected icon stays visible on its pill', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Home',
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
              ),
              PaneItemEntry(
                label: 'Explore',
                icon: Icons.explore_outlined,
                activeIcon: Icons.explore,
              ),
            ],
            paneActions: const [],
            pageBuilder: (page) => const SizedBox(),
            observer: NaviObserver(),
            navigatorKey: GlobalKey<NavigatorState>(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scheme = Theme.of(
        tester.element(find.byType(NaviPane)),
      ).colorScheme;
      // At phone width the side rail is still in the tree (parked off-screen),
      // so the selected activeIcon exists in both nav forms; each paints on a
      // secondaryContainer pill and must use its "on" color to stay visible.
      final selectedIcons = tester
          .widgetList<Icon>(find.byIcon(Icons.home))
          .toList();
      expect(selectedIcons, isNotEmpty);
      for (final icon in selectedIcons) {
        expect(icon.color, isNot(scheme.secondaryContainer));
        expect(icon.color, scheme.onSecondaryContainer);
      }
    });
  });

  group('SliverGridComics reacts to blocked words', () {
    Comic comic(String title) => Comic(
      // An empty cover still makes the tile's image provider arm its
      // load-timeout timer; it is drained by the pump at the end.
      title,
      '',
      title,
      null,
      null,
      '',
      'test',
      null,
      null,
    );

    testWidgets('re-filters without manager listeners when settings change', (
      tester,
    ) async {
      appdata.settings['blockedWords'] = <String>[];
      final comics = [
        comic('Alpha Comic'),
        comic('Beta Comic'),
        comic('Gamma Comic'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverGridComics(comics: comics, listenToManagers: false),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Alpha Comic'), findsOneWidget);
      expect(find.text('Beta Comic'), findsOneWidget);
      expect(find.text('Gamma Comic'), findsOneWidget);

      // A settings write (as done by the keyword-blocking page, backup
      // restore, ...) must re-filter even when the history manager is not
      // listened to.
      appdata.settings['blockedWords'] = <String>['Beta'];
      await tester.pump();
      expect(find.text('Alpha Comic'), findsOneWidget);
      expect(find.text('Beta Comic'), findsNothing);
      expect(find.text('Gamma Comic'), findsOneWidget);

      // Unblocking restores the comic without a parent rebuild.
      appdata.settings['blockedWords'] = <String>[];
      await tester.pump();
      expect(find.text('Beta Comic'), findsOneWidget);

      appdata.settings['blockedWords'] = <String>[];
      // Drain the cover loader's retry backoff chain (2+4+8 seconds).
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
