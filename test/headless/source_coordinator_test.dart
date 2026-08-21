import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/headless/source_coordinator.dart';

void main() {
  test(
    'query concurrency is capped at four while preserving all results',
    () async {
      var coordinator = SourceOperationCoordinator.instance;
      var active = 0;
      var maximum = 0;

      var results = await Future.wait([
        for (var index = 0; index < 8; index++)
          coordinator.query('source-$index', () async {
            active++;
            if (active > maximum) maximum = active;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            active--;
            return index;
          }),
      ]);

      expect(maximum, 4);
      expect(results, [0, 1, 2, 3, 4, 5, 6, 7]);
    },
  );

  test(
    'a source write waits for current readers and excludes later reads',
    () async {
      var coordinator = SourceOperationCoordinator.instance;
      var releaseReader = Completer<void>();
      var readerStarted = Completer<void>();
      var order = <String>[];

      var firstRead = coordinator.query('same-source', () async {
        order.add('read-start');
        readerStarted.complete();
        await releaseReader.future;
        order.add('read-end');
      });
      await readerStarted.future;
      var write = coordinator.write('same-source', () async {
        order.add('write');
      });
      var laterRead = coordinator.query('same-source', () async {
        order.add('later-read');
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(order, ['read-start']);

      releaseReader.complete();
      await Future.wait([firstRead, write, laterRead]);

      expect(order, ['read-start', 'read-end', 'write', 'later-read']);
    },
  );
}
