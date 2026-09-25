import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/app_theme.dart';

/// Drives a real [AppPageRoute] push/pop so the transition builders run to
/// completion, and asserts the page content stays visible afterwards.
///
/// Catches reversed fade tweens: when the fade-out tween starts at 0 instead
/// of 1, the settled page is wrapped in opacity 0 — a blank screen with only
/// chrome (which lives outside the Navigator) visible.
Future<GlobalKey<NavigatorState>> _pushRouteAndSettle(
  WidgetTester tester,
  String marker,
) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(primary: Colors.blue, brightness: Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                AppPageRoute(
                  preventRebuild: false,
                  builder: (_) => Scaffold(body: Center(child: Text(marker))),
                ),
              ),
              child: const Text('push'),
            ),
          ),
        ),
      ),
      navigatorKey: navigatorKey,
    ),
  );
  await tester.tap(find.text('push'));
  await tester.pumpAndSettle(const Duration(seconds: 2));
  return navigatorKey;
}

void main() {
  testWidgets('page content is visible after the route transition settles', (
    tester,
  ) async {
    await _pushRouteAndSettle(tester, 'settled page');
    expect(find.text('settled page'), findsOneWidget);
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('settled page'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    // After the push completes the page must be fully opaque.
    expect(fade.opacity.value, 1.0);
  });

  testWidgets('page content is visible after popping back', (tester) async {
    final navigatorKey = await _pushRouteAndSettle(tester, 'settled page');

    // Pop via the navigator: the page has no back button to pageBack() on.
    navigatorKey.currentState?.pop();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('push'), findsOneWidget);
    expect(find.text('settled page'), findsNothing);

    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('push'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, 1.0);
  });
}
