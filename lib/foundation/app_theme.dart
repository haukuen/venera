import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';

/// Unified spacing tokens based on a 4px grid.
///
/// Use these instead of hardcoded EdgeInsets values.
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Unified border radius tokens, following the Material 3 shape scale.
///
/// Use these instead of hardcoded BorderRadius.circular() values.
abstract final class AppRadius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double xxl = 28;
  static const double full = 999;
}

/// Builds the application [ThemeData].
///
/// This is the single source of truth for the app's Material 3 design system.
/// Every component theme defined here reaches all pages automatically; no page
/// overrides [Theme] locally.
abstract final class AppTheme {
  /// Builds the full theme.
  ///
  /// The user-facing UI font scale is applied through `MediaQuery.textScaler`
  /// (see `MaterialApp.builder` in main.dart), not baked into the type scale,
  /// so it can be capped together with the system scale.
  static ThemeData build({
    required Color primary,
    Color? secondary,
    Color? tertiary,
    required Brightness brightness,
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    final colorScheme = SeedColorScheme.fromSeeds(
      primaryKey: primary,
      secondaryKey: secondary,
      tertiaryKey: tertiary,
      brightness: brightness,
      tones: FlexTones.vividBackground(brightness),
    );
    final base = ThemeData(
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    // Build an explicit M3 type scale. (ThemeData's default textTheme roles
    // carry no fontSize — they rely on M2 inheritance — so we define them
    // here with concrete sizes, which is also what makes the user font scale
    // composable below.)
    var textTheme = _textTheme(colorScheme);
    if (fontFamily != null) {
      textTheme = textTheme.apply(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
      );
    }
    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: _appBarTheme(textTheme, colorScheme),
      filledButtonTheme: _filledButtonTheme(textTheme, colorScheme),
      outlinedButtonTheme: _outlinedButtonTheme(textTheme, colorScheme),
      textButtonTheme: _textButtonTheme(textTheme, colorScheme),
      iconButtonTheme: _iconButtonTheme(colorScheme),
      dialogTheme: _dialogTheme(textTheme, colorScheme),
      cardTheme: _cardTheme(colorScheme),
      chipTheme: _chipTheme(textTheme, colorScheme),
      menuTheme: _menuTheme(colorScheme),
      popupMenuTheme: _popupMenuTheme(textTheme, colorScheme),
      drawerTheme: _drawerTheme(colorScheme),
      bottomSheetTheme: _bottomSheetTheme(colorScheme),
      inputDecorationTheme: _inputDecorationTheme(textTheme, colorScheme),
      listTileTheme: _listTileTheme(textTheme, colorScheme),
      dividerTheme: _dividerTheme(colorScheme),
      progressIndicatorTheme: _progressIndicatorTheme(colorScheme),
      scrollbarTheme: _scrollbarTheme(colorScheme),
      sliderTheme: _sliderTheme(textTheme, colorScheme),
      navigationBarTheme: _navigationBarTheme(textTheme, colorScheme),
      navigationRailTheme: _navigationRailTheme(textTheme, colorScheme),
    );
  }

  /// The Material 3 type scale, with the title roles tuned to preserve the
  /// app's existing visual identity (titleLarge 20, titleMedium 18). Every role
  /// carries an explicit fontSize so the user font scale can multiply it.
  static TextTheme _textTheme(ColorScheme colors) {
    TextStyle style(
      double size,
      FontWeight weight, {
      required double lineHeight,
      double spacing = 0,
      Color? color,
    }) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: lineHeight / size,
        letterSpacing: spacing,
        color: color ?? colors.onSurface,
      );
    }

    final secondary = colors.onSurfaceVariant;
    return TextTheme(
      displayLarge: style(57, FontWeight.w400, lineHeight: 64, spacing: -0.25),
      displayMedium: style(45, FontWeight.w400, lineHeight: 52),
      displaySmall: style(36, FontWeight.w400, lineHeight: 44),
      headlineLarge: style(32, FontWeight.w400, lineHeight: 40),
      headlineMedium: style(28, FontWeight.w400, lineHeight: 36),
      headlineSmall: style(24, FontWeight.w400, lineHeight: 32),
      titleLarge: style(20, FontWeight.w400, lineHeight: 28),
      titleMedium: style(18, FontWeight.w500, lineHeight: 24, spacing: 0.15),
      titleSmall: style(14, FontWeight.w500, lineHeight: 20, spacing: 0.1),
      bodyLarge: style(16, FontWeight.w400, lineHeight: 24, spacing: 0.5),
      bodyMedium: style(14, FontWeight.w400, lineHeight: 20, spacing: 0.25),
      bodySmall: style(12, FontWeight.w400, lineHeight: 16, spacing: 0.4),
      labelLarge: style(
        14,
        FontWeight.w500,
        lineHeight: 20,
        spacing: 0.1,
        color: secondary,
      ),
      labelMedium: style(
        12,
        FontWeight.w500,
        lineHeight: 16,
        spacing: 0.5,
        color: secondary,
      ),
      labelSmall: style(
        11,
        FontWeight.w500,
        lineHeight: 16,
        spacing: 0.5,
        color: secondary,
      ),
    );
  }

  /// The supported range for the user UI font scale and for the composed
  /// system × user text scale.
  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.30;

  /// Composes the user UI font scale with the system text scale and caps the
  /// product, so a large system font size combined with the max app slider
  /// cannot push text past what the fixed-height chrome is laid out for.
  static double effectiveTextScale(double systemScale, double userScale) {
    return (systemScale * userScale).clamp(minTextScale, maxTextScale);
  }

  /// Resolves the standard M3 state layer for a foreground [color]:
  /// hover 8%, focus 10%, press 10%, drag 16%.
  static WidgetStateProperty<Color?> stateLayer(Color color) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) {
        return color.withValues(alpha: 0.10);
      }
      if (states.contains(WidgetState.hovered)) {
        return color.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.dragged)) {
        return color.withValues(alpha: 0.16);
      }
      return null;
    });
  }

  /// Same M3 state layer as [stateLayer], for the [SliderThemeData.overlayColor]
  /// slot which takes a plain [Color].
  static WidgetStateColor _stateLayerColor(Color color) {
    return WidgetStateColor.resolveWith((states) {
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) {
        return color.withValues(alpha: 0.10);
      }
      if (states.contains(WidgetState.hovered)) {
        return color.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.dragged)) {
        return color.withValues(alpha: 0.16);
      }
      return Colors.transparent;
    });
  }

  static AppBarTheme _appBarTheme(TextTheme text, ColorScheme colors) {
    return AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      elevation: 0,
      scrolledUnderElevation: 2,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    );
  }

  static FilledButtonThemeData _filledButtonTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll<Color?>(colors.primary),
        foregroundColor: WidgetStatePropertyAll<Color?>(colors.onPrimary),
        overlayColor: stateLayer(colors.onPrimary),
        textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll<Color?>(colors.primary),
        overlayColor: stateLayer(colors.primary),
        side: WidgetStatePropertyAll<BorderSide?>(
          BorderSide(color: colors.outline, width: 1),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll<Color?>(colors.primary),
        overlayColor: stateLayer(colors.primary),
        textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
      ),
    );
  }

  static IconButtonThemeData _iconButtonTheme(ColorScheme colors) {
    return IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll<Color?>(
          colors.onSurfaceVariant,
        ),
        overlayColor: stateLayer(colors.onSurfaceVariant),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(CircleBorder()),
      ),
    );
  }

  static DialogThemeData _dialogTheme(TextTheme text, ColorScheme colors) {
    return DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        side: BorderSide(
          color: colors.brightness == Brightness.dark
              ? colors.outlineVariant
              : Colors.transparent,
        ),
      ),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
    );
  }

  static CardThemeData _cardTheme(ColorScheme colors) {
    return CardThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: colors.outlineVariant),
      ),
    );
  }

  static ChipThemeData _chipTheme(TextTheme text, ColorScheme colors) {
    return ChipThemeData(
      backgroundColor: colors.surface,
      selectedColor: colors.secondaryContainer,
      side: BorderSide(color: colors.outline),
      labelStyle: text.labelMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    );
  }

  static MenuThemeData _menuTheme(ColorScheme colors) {
    return MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color?>(
          colors.surfaceContainer,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color?>(
          Colors.transparent,
        ),
        side: WidgetStatePropertyAll<BorderSide?>(
          BorderSide(color: colors.outlineVariant),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      ),
    );
  }

  static PopupMenuThemeData _popupMenuTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return PopupMenuThemeData(
      color: colors.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: BorderSide(color: colors.outlineVariant),
      ),
      textStyle: text.labelLarge,
    );
  }

  static DrawerThemeData _drawerTheme(ColorScheme colors) {
    return DrawerThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
    );
  }

  static BottomSheetThemeData _bottomSheetTheme(ColorScheme colors) {
    return BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl),
        ),
      ),
    );
  }

  static InputDecorationTheme _inputDecorationTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return InputDecorationTheme(
      labelStyle: text.bodyMedium,
      hintStyle: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
      errorStyle: text.labelMedium?.copyWith(color: colors.error),
      focusColor: colors.primary.withValues(alpha: 0.08),
      hoverColor: colors.onSurface.withValues(alpha: 0.04),
    );
  }

  static ListTileThemeData _listTileTheme(TextTheme text, ColorScheme colors) {
    return ListTileThemeData(
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall?.copyWith(
        color: colors.onSurfaceVariant,
      ),
      iconColor: colors.onSurfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    );
  }

  static DividerThemeData _dividerTheme(ColorScheme colors) {
    return DividerThemeData(
      color: colors.outlineVariant,
      thickness: 1,
      space: 1,
    );
  }

  static ProgressIndicatorThemeData _progressIndicatorTheme(
    ColorScheme colors,
  ) {
    return ProgressIndicatorThemeData(
      color: colors.primary,
      linearTrackColor: colors.surfaceContainer,
      circularTrackColor: colors.surfaceContainer,
    );
  }

  static ScrollbarThemeData _scrollbarTheme(ColorScheme colors) {
    return ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color?>(
        colors.onSurfaceVariant.withValues(alpha: 0.4),
      ),
      trackColor: const WidgetStatePropertyAll<Color?>(Colors.transparent),
      thickness: const WidgetStatePropertyAll<double>(8),
      radius: const Radius.circular(AppRadius.full),
    );
  }

  static SliderThemeData _sliderTheme(TextTheme text, ColorScheme colors) {
    return SliderThemeData(
      trackHeight: 4.0,
      activeTrackColor: colors.primary,
      inactiveTrackColor: colors.surfaceContainerHighest,
      secondaryActiveTrackColor: colors.primary.withValues(alpha: 0.54),
      disabledActiveTrackColor: colors.onSurface.withValues(alpha: 0.38),
      disabledInactiveTrackColor: colors.onSurface.withValues(alpha: 0.12),
      disabledSecondaryActiveTrackColor: colors.onSurface.withValues(
        alpha: 0.12,
      ),
      activeTickMarkColor: colors.onPrimary.withValues(alpha: 0.38),
      inactiveTickMarkColor: colors.onSurfaceVariant.withValues(alpha: 0.38),
      disabledActiveTickMarkColor: colors.onSurface.withValues(alpha: 0.38),
      disabledInactiveTickMarkColor: colors.onSurface.withValues(alpha: 0.38),
      thumbColor: colors.primary,
      disabledThumbColor: Color.alphaBlend(
        colors.onSurface.withValues(alpha: 0.38),
        colors.surface,
      ),
      overlayColor: _stateLayerColor(colors.primary),
      valueIndicatorTextStyle: text.labelMedium?.copyWith(
        color: colors.onPrimary,
      ),
      valueIndicatorShape: const DropSliderValueIndicatorShape(),
    );
  }

  static NavigationBarThemeData _navigationBarTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return NavigationBarThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colors.secondaryContainer,
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll<TextStyle?>(text.labelSmall),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: selected
              ? colors.onSecondaryContainer
              : colors.onSurfaceVariant,
        );
      }),
    );
  }

  static NavigationRailThemeData _navigationRailTheme(
    TextTheme text,
    ColorScheme colors,
  ) {
    return NavigationRailThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.secondaryContainer,
      selectedIconTheme: IconThemeData(
        size: 24,
        color: colors.onSecondaryContainer,
      ),
      unselectedIconTheme: IconThemeData(
        size: 24,
        color: colors.onSurfaceVariant,
      ),
      selectedLabelTextStyle: text.labelMedium?.copyWith(
        color: colors.onSurface,
      ),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(
        color: colors.onSurfaceVariant,
      ),
    );
  }
}
