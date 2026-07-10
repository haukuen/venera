import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/translations.dart';

class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.title,
    this.subtitle,
    this.minLength = 4,
    this.maxLength = 6,
    this.autoSubmitAt,
    this.showHelpButton = false,
    required this.onSubmit,
  });

  final String title;
  final String? subtitle;
  final int minLength;
  final int maxLength;
  final int? autoSubmitAt;
  final bool showHelpButton;
  final void Function(String pin) onSubmit;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  static const _keySize = 64.0;
  static const _keySpacing = 32.0;
  static const _keypadWidth = _keySize * 3 + _keySpacing * 2;

  final StringBuffer _input = StringBuffer();
  bool _isSubmitting = false;

  int get length => _input.length;

  void _append(String digit) {
    if (_isSubmitting || _input.length >= widget.maxLength) return;
    setState(() {
      _input.write(digit);
    });
    final target = widget.autoSubmitAt;
    if (target != null && _input.length == target) {
      _submit();
    }
  }

  void _delete() {
    if (_isSubmitting || _input.isEmpty) return;
    setState(() {
      final s = _input.toString();
      _input.clear();
      _input.write(s.substring(0, s.length - 1));
    });
  }

  void _submit() {
    if (_input.length < widget.minLength || _isSubmitting) return;
    setState(() {
      _isSubmitting = true;
    });
    widget.onSubmit(_input.toString());
  }

  void reset() {
    setState(() {
      _input.clear();
      _isSubmitting = false;
    });
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "About PIN".tl,
        content: Text(
          "PIN is stored locally and cannot be recovered. If forgotten, app data must be cleared."
              .tl,
        ).paddingHorizontal(16),
        actions: [
          Button.filled(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("OK".tl),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(bool filled) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? context.colorScheme.primary : null,
        border: Border.all(color: context.colorScheme.outline, width: 1.5),
      ),
    );
  }

  Widget _buildKey({String? digit, Widget? icon, required VoidCallback onTap}) {
    return InkWell(
      onTap: _isSubmitting ? null : onTap,
      borderRadius: BorderRadius.circular(32),
      child: SizedBox(
        width: _keySize,
        height: _keySize,
        child: Center(
          child:
              icon ??
              Text(
                digit!,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w400,
                ),
              ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showConfirm = widget.autoSubmitAt == null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          if (widget.subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.subtitle!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          Builder(
            builder: (context) {
              final slotCount = _input.length > widget.minLength
                  ? _input.length
                  : widget.minLength;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(slotCount, (i) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: _buildDot(i < _input.length),
                  );
                }),
              );
            },
          ),
          const SizedBox(height: 24),
          SizedBox(width: _keypadWidth, child: _buildKeypad()),
          if (showConfirm) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: _keypadWidth,
              child: FilledButton(
                onPressed: _input.length >= widget.minLength && !_isSubmitting
                    ? _submit
                    : null,
                child: Text("OK".tl),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKeypad() {
    final keys = <Widget>[];
    for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9']) {
      keys.add(_buildKey(digit: d, onTap: () => _append(d)));
    }
    if (widget.showHelpButton) {
      keys.add(
        _buildKey(
          icon: const Icon(Icons.help_outline, size: 26),
          onTap: _showHelp,
        ),
      );
    } else {
      keys.add(const SizedBox(width: _keySize, height: _keySize));
    }
    keys.add(_buildKey(digit: '0', onTap: () => _append('0')));
    keys.add(
      _buildKey(icon: const Icon(Icons.backspace, size: 26), onTap: _delete),
    );

    return Column(
      children: [
        for (int r = 0; r < 4; r++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: keys.sublist(r * 3, r * 3 + 3),
            ),
          ),
      ],
    );
  }
}
