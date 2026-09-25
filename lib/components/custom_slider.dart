import 'package:flutter/material.dart';

class CustomSlider extends StatefulWidget {
  const CustomSlider({
    required this.min,
    required this.max,
    required this.value,
    required this.divisions,
    required this.onChanged,
    required this.focusNode,
    this.reversed = false,
    super.key,
  });

  final double min;

  final double max;

  final double value;

  final int divisions;

  final void Function(double) onChanged;

  final FocusNode? focusNode;

  final bool reversed;

  @override
  State<CustomSlider> createState() => _CustomSliderState();
}

class _CustomSliderState extends State<CustomSlider> {
  late double value;

  @override
  void initState() {
    super.initState();
    value = widget.value;
  }

  @override
  void didUpdateWidget(CustomSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      setState(() {
        value = widget.value;
      });
    }
  }

  double get _step {
    return widget.divisions > 0
        ? (widget.max - widget.min) / widget.divisions
        : 0;
  }

  /// Human-readable current value for screen readers.
  String _formatValue() {
    final step = _step;
    final precision = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2);
    return value.toStringAsFixed(precision);
  }

  /// The value one step up / down, or null when already at that end. A node
  /// that advertises increase/decrease must declare its target value, so the
  /// matching action is withheld when there is no target.
  String? _formatTarget(double direction) {
    if (widget.divisions <= 0) return null;
    final next = (value + direction * _step).clamp(widget.min, widget.max);
    if (next == value) return null;
    final step = _step;
    final precision = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2);
    return next.toStringAsFixed(precision);
  }

  void _nudge(double direction) {
    if (widget.divisions <= 0) return;
    final next = (value + direction * _step).clamp(widget.min, widget.max);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).sliderTheme;
    final increased = _formatTarget(1);
    final decreased = _formatTarget(-1);
    return Semantics(
      slider: true,
      value: _formatValue(),
      increasedValue: increased,
      decreasedValue: decreased,
      // Only advertise an action when it would actually change the value;
      // otherwise the node carries an increase/decrease action with no
      // target value, which Flutter rejects during semantics flush.
      onIncrease: increased == null ? null : () => _nudge(1),
      onDecrease: decreased == null ? null : () => _nudge(-1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: widget.max - widget.min > 0
            ? LayoutBuilder(
                builder: (context, constraints) => MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: (details) {
                      var dx = details.localPosition.dx;
                      if (widget.reversed) {
                        dx = constraints.maxWidth - dx;
                      }
                      var gap = constraints.maxWidth / widget.divisions;
                      var gapValue =
                          (widget.max - widget.min) / widget.divisions;
                      widget.onChanged.call(
                        (dx / gap).round() * gapValue + widget.min,
                      );
                    },
                    onVerticalDragUpdate: (details) {
                      var dx = details.localPosition.dx;
                      if (dx > constraints.maxWidth || dx < 0) return;
                      if (widget.reversed) {
                        dx = constraints.maxWidth - dx;
                      }
                      var gap = constraints.maxWidth / widget.divisions;
                      var gapValue =
                          (widget.max - widget.min) / widget.divisions;
                      widget.onChanged.call(
                        (dx / gap).round() * gapValue + widget.min,
                      );
                    },
                    child: SizedBox(
                      // 48px touch target; the visible track is centered inside.
                      height: 48,
                      child: Center(
                        child: SizedBox(
                          height: 24,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: Center(
                                  child: Container(
                                    width: double.infinity,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: theme.inactiveTrackColor,
                                      borderRadius: const BorderRadius.all(
                                        Radius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (constraints.maxWidth / widget.divisions > 10)
                                Positioned.fill(
                                  child: Row(
                                    children: () {
                                      var res = <Widget>[];
                                      for (
                                        int i = 0;
                                        i < widget.divisions - 1;
                                        i++
                                      ) {
                                        res.add(const Spacer());
                                        res.add(
                                          Container(
                                            width: 4,
                                            height: 4,
                                            decoration: BoxDecoration(
                                              color: colorScheme.surface
                                                  .withRed(10),
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        );
                                      }
                                      res.add(const Spacer());
                                      return res;
                                    }.call(),
                                  ),
                                ),
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: widget.reversed ? null : 0,
                                right: widget.reversed ? 0 : null,
                                child: Center(
                                  child: Container(
                                    width:
                                        constraints.maxWidth *
                                        ((value - widget.min) /
                                            (widget.max - widget.min)),
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: theme.activeTrackColor,
                                      borderRadius: const BorderRadius.all(
                                        Radius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: widget.reversed
                                    ? null
                                    : constraints.maxWidth *
                                              ((value - widget.min) /
                                                  (widget.max - widget.min)) -
                                          11,
                                right: !widget.reversed
                                    ? null
                                    : constraints.maxWidth *
                                              ((value - widget.min) /
                                                  (widget.max - widget.min)) -
                                          11,
                                child: Center(
                                  child: Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      color: theme.activeTrackColor,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
