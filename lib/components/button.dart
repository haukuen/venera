part of 'components.dart';

class HoverBox extends StatefulWidget {
  const HoverBox({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;

  final BorderRadius borderRadius;

  @override
  State<HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<HoverBox> {
  bool isHover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHover = true),
      onExit: (_) => setState(() => isHover = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isHover
              ? Theme.of(context).colorScheme.surfaceContainerLow
              : null,
          borderRadius: widget.borderRadius,
        ),
        child: widget.child,
      ),
    );
  }
}

enum ButtonType { filled, outlined, text, normal }

class Button extends StatefulWidget {
  const Button({
    super.key,
    required this.type,
    required this.child,
    this.isLoading = false,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    required this.onPressed,
  });

  const Button.filled({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.filled;

  const Button.outlined({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.outlined;

  const Button.text({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.text;

  const Button.normal({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.normal;

  static Widget icon({
    Key? key,
    required Widget icon,
    required VoidCallback onPressed,
    double? size,
    Color? color,
    String? tooltip,
    bool isLoading = false,
    HitTestBehavior behavior = HitTestBehavior.deferToChild,
  }) {
    return _IconButton(
      key: key,
      icon: icon,
      onPressed: onPressed,
      size: size,
      color: color,
      tooltip: tooltip,
      behavior: behavior,
      isLoading: isLoading,
    );
  }

  final ButtonType type;

  final Widget child;

  final bool isLoading;

  final void Function() onPressed;

  final void Function(Offset location)? onPressedAt;

  final double? width;

  final double? height;

  final EdgeInsets? padding;

  final Color? color;

  @override
  State<Button> createState() => _ButtonState();
}

class _ButtonState extends State<Button> {
  bool isLoading = false;

  @override
  void didUpdateWidget(covariant Button oldWidget) {
    if (oldWidget.isLoading != widget.isLoading) {
      setState(() => isLoading = widget.isLoading);
    }
    super.didUpdateWidget(oldWidget);
  }

  /// The container color. Unlike the previous hover-swap, the base color is
  /// constant and interaction is shown through the M3 state layer.
  Color get _baseColor {
    switch (widget.type) {
      case ButtonType.filled:
        return widget.color ?? context.colorScheme.primary;
      case ButtonType.normal:
        return widget.color ?? context.colorScheme.surfaceContainer;
      case ButtonType.text:
      case ButtonType.outlined:
        return Colors.transparent;
    }
  }

  Color get _foregroundColor {
    switch (widget.type) {
      case ButtonType.filled:
        return context.colorScheme.onPrimary;
      case ButtonType.normal:
        return context.colorScheme.onSurface;
      case ButtonType.text:
      case ButtonType.outlined:
        return widget.color ?? context.colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    var padding = widget.padding ?? const EdgeInsets.symmetric(horizontal: 16);
    var width = widget.width;
    if (width != null) {
      width = width - padding.horizontal;
    }
    var height = widget.height;
    if (height != null) {
      height = height - padding.vertical;
    }
    final foreground = _foregroundColor;
    Widget child = IconTheme(
      data: IconThemeData(color: foreground),
      child: DefaultTextStyle(
        style:
            context.textTheme.labelLarge?.copyWith(color: foreground) ??
            DefaultTextStyle.of(context).style,
        child: isLoading
            ? CircularProgressIndicator(
                color: widget.type == ButtonType.filled
                    ? context.colorScheme.inversePrimary
                    : context.colorScheme.primary,
                strokeWidth: 1.8,
              ).fixWidth(16).fixHeight(16)
            : widget.child,
      ),
    );
    if (width != null || height != null) {
      child = child.toCenter();
    }
    const radius = BorderRadius.all(Radius.circular(16));
    final isOutlined = widget.type == ButtonType.outlined;
    return Material(
      color: _baseColor,
      // Material rejects both shape and borderRadius at once; the outlined
      // variant carries its border in the shape.
      shape: isOutlined
          ? RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(
                color: widget.color ?? context.colorScheme.outlineVariant,
                width: 0.6,
              ),
            )
          : null,
      borderRadius: isOutlined ? null : radius,
      clipBehavior: isOutlined ? Clip.antiAlias : Clip.none,
      child: InkWell(
        onTap: isLoading
            ? null
            : () {
                widget.onPressed();
                if (widget.onPressedAt != null) {
                  var renderBox = context.findRenderObject() as RenderBox;
                  var offset = renderBox.localToGlobal(Offset.zero);
                  widget.onPressedAt!(offset);
                }
              },
        customBorder: const RoundedRectangleBorder(borderRadius: radius),
        overlayColor: AppTheme.stateLayer(foreground),
        mouseCursor: isLoading
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 76, minHeight: 32),
          child: Padding(
            padding: padding,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 160),
              child: SizedBox(
                width: width,
                height: height,
                child: Center(widthFactor: 1, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatefulWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size,
    this.color,
    this.tooltip,
    this.isLoading = false,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final Widget icon;

  final VoidCallback onPressed;

  final double? size;

  final String? tooltip;

  final Color? color;

  final HitTestBehavior behavior;

  final bool isLoading;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  @override
  Widget build(BuildContext context) {
    var iconSize = widget.size ?? 24;
    final color = widget.color ?? context.colorScheme.primary;
    Widget icon = IconTheme(
      data: IconThemeData(size: iconSize, color: color),
      child: widget.icon,
    );
    if (widget.isLoading) {
      icon = CircularProgressIndicator(
        color: color,
        strokeWidth: 1.5,
      ).paddingAll(2).fixWidth(iconSize).fixHeight(iconSize);
    }
    return GestureDetector(
      behavior: widget.behavior,
      child: Tooltip(
        message: widget.tooltip ?? '',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () {
              if (widget.isLoading) return;
              widget.onPressed();
            },
            customBorder: const CircleBorder(),
            overlayColor: AppTheme.stateLayer(color),
            child: Padding(padding: const EdgeInsets.all(6), child: icon),
          ),
        ),
      ),
    );
  }
}

class MenuButton extends StatefulWidget {
  const MenuButton({super.key, required this.entries});

  final List<MenuEntry> entries;

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'more'.tl,
      child: Button.icon(
        icon: const Icon(Icons.more_horiz),
        onPressed: () {
          var renderBox = context.findRenderObject() as RenderBox;
          var offset = renderBox.localToGlobal(Offset.zero);
          showMenuX(context, offset, widget.entries);
        },
      ),
    );
  }
}
