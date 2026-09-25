import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_theme.dart';

ThemeData buildTheme({
  Brightness brightness = Brightness.light,
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  return AppTheme.build(
    primary: Colors.blue,
    secondary: Colors.green,
    tertiary: Colors.orange,
    brightness: brightness,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
  );
}

void main() {
  group('AppTheme text scale', () {
    test('tuned title roles match the existing visual identity', () {
      final text = buildTheme().textTheme;
      expect(text.titleLarge?.fontSize, 20);
      expect(text.titleMedium?.fontSize, 18);
      expect(text.titleSmall?.fontSize, 14);
    });

    test('body and label roles keep the M3 defaults', () {
      final text = buildTheme().textTheme;
      expect(text.bodyLarge?.fontSize, 16);
      expect(text.bodyMedium?.fontSize, 14);
      expect(text.bodySmall?.fontSize, 12);
      expect(text.labelLarge?.fontSize, 14);
      expect(text.labelMedium?.fontSize, 12);
      expect(text.labelSmall?.fontSize, 11);
      expect(text.headlineSmall?.fontSize, 24);
    });

    test('fontFamily is applied across every role', () {
      final text = buildTheme(
        fontFamily: 'Noto Sans CJK',
        fontFamilyFallback: ['Segoe UI'],
      ).textTheme;
      expect(text.bodyLarge?.fontFamily, 'Noto Sans CJK');
      expect(text.titleLarge?.fontFamily, 'Noto Sans CJK');
      expect(text.bodyLarge?.fontFamilyFallback, ['Segoe UI']);
    });

    test('every role carries a concrete fontSize for scalable text', () {
      // The user font scale flows through MediaQuery.textScaler, which needs
      // real font sizes on every role to scale them.
      final text = buildTheme().textTheme;
      final roles = <String, TextStyle?>{
        'displayLarge': text.displayLarge,
        'displayMedium': text.displayMedium,
        'displaySmall': text.displaySmall,
        'headlineLarge': text.headlineLarge,
        'headlineMedium': text.headlineMedium,
        'headlineSmall': text.headlineSmall,
        'titleLarge': text.titleLarge,
        'titleMedium': text.titleMedium,
        'titleSmall': text.titleSmall,
        'bodyLarge': text.bodyLarge,
        'bodyMedium': text.bodyMedium,
        'bodySmall': text.bodySmall,
        'labelLarge': text.labelLarge,
        'labelMedium': text.labelMedium,
        'labelSmall': text.labelSmall,
      };
      for (final entry in roles.entries) {
        expect(entry.value, isNotNull, reason: '${entry.key} is null');
        expect(entry.value!.fontSize, isNotNull, reason: entry.key);
      }
    });
  });

  group('AppTheme component themes', () {
    test('are populated for both brightnesses', () {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final theme = buildTheme(brightness: brightness);
        expect(theme.appBarTheme.backgroundColor, theme.colorScheme.surface);
        expect(theme.appBarTheme.titleTextStyle, isNotNull);
        expect(theme.filledButtonTheme.style, isNotNull);
        expect(theme.outlinedButtonTheme.style, isNotNull);
        expect(theme.textButtonTheme.style, isNotNull);
        expect(theme.iconButtonTheme.style, isNotNull);
        expect(theme.dialogTheme.shape, isNotNull);
        expect(theme.cardTheme.shape, isNotNull);
        expect(theme.chipTheme.shape, isNotNull);
        expect(theme.menuTheme.style, isNotNull);
        expect(theme.popupMenuTheme.shape, isNotNull);
        expect(theme.drawerTheme.shape, isNotNull);
        expect(theme.bottomSheetTheme.shape, isNotNull);
        expect(theme.listTileTheme.titleTextStyle, isNotNull);
        expect(theme.navigationBarTheme.indicatorColor, isNotNull);
        expect(theme.navigationRailTheme.indicatorColor, isNotNull);
      }
    });

    test('buttons use the scheme primary as foreground', () {
      final theme = buildTheme();
      final colors = theme.colorScheme;
      expect(
        theme.filledButtonTheme.style?.backgroundColor?.resolve({}),
        colors.primary,
      );
      expect(
        theme.filledButtonTheme.style?.foregroundColor?.resolve({}),
        colors.onPrimary,
      );
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve({}),
        colors.primary,
      );
      expect(
        theme.outlinedButtonTheme.style?.side?.resolve({})?.color,
        colors.outline,
      );
    });

    test('surfaces are opaque so the app keeps a flat look', () {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final theme = buildTheme(brightness: brightness);
        expect(theme.dialogTheme.backgroundColor, theme.colorScheme.surface);
        expect(theme.dialogTheme.surfaceTintColor, Colors.transparent);
        expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
        expect(theme.drawerTheme.surfaceTintColor, Colors.transparent);
        expect(theme.navigationBarTheme.surfaceTintColor, Colors.transparent);
      }
    });

    test('slider theme carries the shared M3 palette', () {
      final theme = buildTheme();
      final colors = theme.colorScheme;
      expect(theme.sliderTheme.activeTrackColor, colors.primary);
      expect(
        theme.sliderTheme.inactiveTrackColor,
        colors.surfaceContainerHighest,
      );
      expect(theme.sliderTheme.thumbColor, colors.primary);
      expect(theme.sliderTheme.trackHeight, 4.0);
    });
  });

  group('AppTheme state layer', () {
    test('resolves the M3 opacity for each interaction state', () {
      final layer = AppTheme.stateLayer(Colors.black);
      expect(layer.resolve(const <WidgetState>{}), isNull);
      expect(
        layer.resolve(const <WidgetState>{WidgetState.hovered})!.a,
        closeTo(0.08, 0.001),
      );
      expect(
        layer.resolve(const <WidgetState>{WidgetState.focused})!.a,
        closeTo(0.10, 0.001),
      );
      expect(
        layer.resolve(const <WidgetState>{WidgetState.pressed})!.a,
        closeTo(0.10, 0.001),
      );
      expect(
        layer.resolve(const <WidgetState>{WidgetState.dragged})!.a,
        closeTo(0.16, 0.001),
      );
    });
  });

  group('AppTheme effective text scale', () {
    test('composes system × user and caps the product at 1.30', () {
      expect(AppTheme.effectiveTextScale(1.0, 1.0), 1.0);
      expect(AppTheme.effectiveTextScale(1.0, 1.3), 1.3);
      expect(AppTheme.effectiveTextScale(1.5, 1.0), 1.3);
      // The case that motivated capping: system 1.3 × slider 1.3 would be
      // 1.69 without the clamp.
      expect(AppTheme.effectiveTextScale(1.3, 1.3), 1.3);
    });

    test('clamps the lower bound so text never disappears', () {
      expect(AppTheme.effectiveTextScale(1.0, 0.85), 0.85);
      expect(AppTheme.effectiveTextScale(0.5, 1.0), 0.85);
      expect(AppTheme.effectiveTextScale(0.5, 0.85), 0.85);
    });
  });

  group('AppRadius shape scale', () {
    test('follows the M3 shape ladder', () {
      expect(AppRadius.sm, 4);
      expect(AppRadius.md, 8);
      expect(AppRadius.lg, 12);
      expect(AppRadius.xl, 16);
      expect(AppRadius.xxl, 28);
      expect(AppRadius.full, greaterThan(AppRadius.xxl));
    });
  });
}
