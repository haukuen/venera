part of 'settings_page.dart';

class AuthPinSetting extends StatefulWidget {
  const AuthPinSetting({super.key});

  @override
  State<AuthPinSetting> createState() => _AuthPinSettingState();
}

class _AuthPinSettingState extends State<AuthPinSetting> {
  int _stage = 0;
  String? _firstPin;
  final _confirmKey = GlobalKey<PinPadState>();

  String get _title => _stage == 0 ? "Set PIN".tl : "Confirm PIN".tl;

  void _onStage0Submit(String pin) {
    _firstPin = pin;
    setState(() {
      _stage = 1;
    });
  }

  Future<void> _onStage1Submit(String pin) async {
    if (pin == _firstPin) {
      try {
        await AuthStorage.setPin(pin);
      } catch (_) {
        if (!mounted) return;
        context.showMessage(message: "Failed to save PIN".tl);
        _confirmKey.currentState?.reset();
        return;
      }
      if (!mounted) return;
      context.showMessage(message: "PIN set".tl);
      App.pop();
    } else {
      context.showMessage(message: "PINs do not match".tl);
      _confirmKey.currentState?.reset();
    }
  }

  Future<void> _clearPin() async {
    final auth = LocalAuthentication();
    bool canAuthenticate;
    try {
      canAuthenticate =
          await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {
      canAuthenticate = false;
    }
    if (!canAuthenticate) {
      appdata.settings['authorizationRequired'] = false;
      await appdata.saveData();
    }
    try {
      await AuthStorage.clearPin();
    } catch (_) {
      if (!mounted) return;
      context.showMessage(message: "Failed to clear PIN".tl);
      return;
    }
    if (!mounted) return;
    context.showMessage(message: "PIN cleared".tl);
    App.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: _title,
      tailing: AuthStorage.hasPin
          ? [TextButton(onPressed: _clearPin, child: Text("Clear PIN".tl))]
          : null,
      body: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "PIN is stored locally and cannot be recovered. If forgotten, app data must be cleared."
                            .tl,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _stage == 0
                  ? PinPad(
                      key: const ValueKey(0),
                      title: "Enter PIN".tl,
                      onSubmit: _onStage0Submit,
                    )
                  : PinPad(
                      key: _confirmKey,
                      title: "Re-enter PIN".tl,
                      onSubmit: _onStage1Submit,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
