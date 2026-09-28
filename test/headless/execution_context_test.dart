import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/js_ui.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/contract.dart';
import 'package:venera/headless/execution_context.dart';
import 'package:venera/headless/gui_session.dart';

void main() {
  const options = CliGlobalOptions(
    json: true,
    allowGui: false,
    recordHistory: false,
    quiet: false,
    noColor: true,
    ignoreHeadlessLog: false,
    timeout: Duration(seconds: 1),
  );

  test('non-interactive QuickJS messages become CLI events', () async {
    var events = <String>[];
    var reporter = CliReporter((type, data) => events.add(type));
    var context = CliExecutionContext(
      requestId: 'request',
      command: 'test',
      options: options,
      transport: CliTransport.direct,
      reporter: reporter,
      cancellation: CliCancellationToken(),
      guiAvailable: false,
    );
    var ui = _TestUi();

    await context.run(() async {
      ui.handleUIMessage({'function': 'showMessage', 'message': 'notice'});
      var loading = ui.handleUIMessage({
        'function': 'showLoading',
        'message': 'loading',
      });
      ui.handleUIMessage({'function': 'cancelLoading', 'id': loading});
    });

    expect(events, ['warning', 'progress']);
    expect(reporter.warnings.single.code, 'source_message');
  });

  test('interactive QuickJS requests fail explicitly without a GUI', () async {
    var context = CliExecutionContext(
      requestId: 'request',
      command: 'test',
      options: options,
      transport: CliTransport.direct,
      reporter: CliReporter(),
      cancellation: CliCancellationToken(),
      guiAvailable: false,
    );

    await expectLater(
      context.run(() async {
        _TestUi().handleUIMessage({'function': 'showInputDialog'});
      }),
      throwsA(isA<CliInteractiveRequiredException>()),
    );
  });

  test('ignored interactive requests remain visible to the runner', () async {
    var context = CliExecutionContext(
      requestId: 'request',
      command: 'test',
      options: options,
      transport: CliTransport.direct,
      reporter: CliReporter(),
      cancellation: CliCancellationToken(),
      guiAvailable: false,
    );

    await context.run(() async {
      try {
        _TestUi().handleUIMessage({
          'function': 'showDialog',
          'title': 'ignored',
        });
      } on CliInteractiveRequiredException {
        // Mirrors a source that does not await or catches the UI promise.
      }
    });

    expect(
      context.throwIfInteractiveRequired,
      throwsA(isA<CliInteractiveRequiredException>()),
    );
  });

  group('GUI session authorization', () {
    tearDown(() {
      CliGuiSession.instance
        ..configure(authorizationRequired: false, authenticated: true)
        ..registerUnlockRequester(null);
    });

    test('locked GUI rejects jobs without --allow-gui', () async {
      CliGuiSession.instance.configure(
        authorizationRequired: true,
        authenticated: false,
      );
      var invocation = CliCommandRunner.parseInvocation(const [
        'source',
        'list',
      ]);

      await expectLater(
        CliGuiSession.instance.authorize(invocation, CliCancellationToken()),
        throwsA(
          isA<CliFailure>().having((error) => error.code, 'code', 'app_locked'),
        ),
      );
    });

    test('--allow-gui focuses the GUI and waits for session unlock', () async {
      var requested = 0;
      CliGuiSession.instance
        ..configure(authorizationRequired: true, authenticated: false)
        ..registerUnlockRequester(() async {
          requested++;
          Timer(
            const Duration(milliseconds: 10),
            () => CliGuiSession.instance.markAuthenticated(true),
          );
        });
      var invocation = CliCommandRunner.parseInvocation(const [
        'source',
        'list',
        '--allow-gui',
      ]);

      await CliGuiSession.instance.authorize(
        invocation,
        CliCancellationToken(),
      );

      expect(requested, 1);
      expect(CliGuiSession.instance.isLocked, isFalse);
    });
  });
}

class _TestUi with JsUiApi {}
