import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';

void main() {
  const displays = [
    Rect.fromLTWH(0, 0, 1920, 1080),
    Rect.fromLTWH(-1920, 0, 1920, 1080),
    Rect.fromLTWH(0, -1080, 1920, 1080),
  ];

  test('accepts windows on primary and negative-coordinate monitors', () {
    for (final position in [
      const Offset(100, 100),
      const Offset(-1500, 100),
      const Offset(100, -900),
    ]) {
      expect(
        WindowPlacement.overlapsDisplays(
          position & const Size(900, 600),
          displays,
        ),
        isTrue,
      );
    }
  });

  test('rejects windows outside every display', () {
    expect(
      WindowPlacement.overlapsDisplays(
        const Rect.fromLTWH(5000, 5000, 900, 600),
        displays,
      ),
      isFalse,
    );
  });

  test('requires at least 100 by 50 pixels of overlap', () {
    for (final rect in [
      const Rect.fromLTWH(1821, 100, 900, 600),
      const Rect.fromLTWH(100, 1031, 900, 600),
      Rect.zero,
    ]) {
      expect(WindowPlacement.overlapsDisplays(rect, displays), isFalse);
    }
    expect(
      WindowPlacement.overlapsDisplays(
        const Rect.fromLTWH(1820, 1030, 900, 600),
        displays,
      ),
      isTrue,
    );
  });

  test('allows placement when no displays are available', () {
    expect(
      WindowPlacement.overlapsDisplays(
        const Rect.fromLTWH(-5000, 5000, 900, 600),
        const [],
      ),
      isTrue,
    );
  });
}
