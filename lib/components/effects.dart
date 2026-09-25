part of 'components.dart';

class BlurEffect extends StatelessWidget {
  final Widget child;

  final double blur;

  final BorderRadius? borderRadius;

  const BlurEffect({
    required this.child,
    this.borderRadius,
    this.blur = 15,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.mirror,
        ),
        child: child,
      ),
    );
  }
}

/// Shared surface recipe for popover-style overlays (menus, flyouts, popups,
/// side bars). Blurred, elevated, and outlined in dark mode, using the M3
/// shape tokens so every overlay reads as the same family of surface.
class PopoverSurface extends StatelessWidget {
  const PopoverSurface({
    required this.child,
    this.radius = AppRadius.sm,
    this.opacity = 0.92,
    this.elevation = 8,
    super.key,
  });

  final Widget child;
  final double radius;
  final double opacity;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: context.brightness == Brightness.dark
            ? Border.all(color: colors.outlineVariant)
            : null,
        boxShadow: [
          BoxShadow(
            color: colors.shadow.toOpacity(0.2),
            blurRadius: elevation,
            blurStyle: BlurStyle.outer,
          ),
        ],
      ),
      child: BlurEffect(
        borderRadius: borderRadius,
        child: Material(
          color: colors.surface.toOpacity(opacity),
          borderRadius: borderRadius,
          child: child,
        ),
      ),
    );
  }
}
