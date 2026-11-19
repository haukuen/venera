import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  for (final state in ['maximized', 'fullscreen']) {
    test('keeps restored normal bounds while $state', () async {
      final directory = await Directory.systemTemp.createTemp('placement_test');
      App.dataPath = directory.path;
      const normal = WindowPlacement(Rect.fromLTWH(100, 80, 900, 700), true);
      var expanded = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          switch (call.method) {
            case 'isMaximized':
              return expanded && state == 'maximized';
            case 'isFullScreen':
              return expanded && state == 'fullscreen';
            case 'maximize':
              expanded = true;
              return null;
            case 'getBounds':
              return {'x': -8.0, 'y': -8.0, 'width': 1936.0, 'height': 1096.0};
            default:
              return null;
          }
        },
      );
      try {
        await normal.applyToWindow();
        expect(WindowPlacement.cache.rect, normal.rect);
        WindowPlacement.loop();
        final file = File('${directory.path}/window_placement');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (WindowPlacement.cache.isMaximized != true &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final saved = jsonDecode(await file.readAsString());
        expect(saved['x'], 100);
        expect(saved['y'], 80);
        expect(saved['width'], 900);
        expect(saved['height'], 700);
        expect(saved['isMaximized'], isTrue);
      } finally {
        WindowPlacement.timer?.cancel();
        WindowPlacement.timer = null;
        messenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        );
        await directory.delete(recursive: true);
      }
    });
  }
}
