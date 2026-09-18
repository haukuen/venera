import 'dart:async';

import 'command_runner.dart';
import 'contract.dart';

typedef GuiUnlockRequester = Future<void> Function();

/// Bridges the GUI's session lock to IPC jobs without accepting credentials on
/// the command line.
class CliGuiSession {
  CliGuiSession._();

  static final CliGuiSession instance = CliGuiSession._();

  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _authorizationRequired = false;
  bool _authenticated = true;
  GuiUnlockRequester? _requestUnlock;

  bool get isLocked => _authorizationRequired && !_authenticated;

  void configure({
    required bool authorizationRequired,
    required bool authenticated,
  }) {
    var nextAuthenticated = !authorizationRequired || authenticated;
    if (_authorizationRequired == authorizationRequired &&
        _authenticated == nextAuthenticated) {
      return;
    }
    _authorizationRequired = authorizationRequired;
    _authenticated = nextAuthenticated;
    _changes.add(null);
  }

  void markAuthenticated(bool value) {
    var next = !_authorizationRequired || value;
    if (_authenticated == next) return;
    _authenticated = next;
    _changes.add(null);
  }

  void registerUnlockRequester(GuiUnlockRequester? requester) {
    _requestUnlock = requester;
  }

  Future<void> authorize(
    CliParsedInvocation invocation,
    CliCancellationToken cancellation,
  ) async {
    if (!isLocked) return;
    if (!invocation.options.allowGui) throw CliFailure.appLocked();

    var requester = _requestUnlock;
    if (requester == null) {
      throw CliFailure.appLocked();
    }
    await requester();
    if (!isLocked) return;

    try {
      await Future.any<void>([
        _changes.stream.firstWhere((_) => !isLocked),
        cancellation.whenCancelled.then((_) => throw CliFailure.cancelled()),
      ]).timeout(invocation.options.timeout);
    } on TimeoutException {
      throw CliFailure(
        code: 'timeout',
        message: 'Timed out waiting for GUI authentication.',
        exitCode: CliExitCode.cancelled,
      );
    }
  }
}
