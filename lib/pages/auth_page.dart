import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera/components/pin_pad.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/auth_storage.dart';
import 'package:venera/utils/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool _usePin = false;
  final _pinKey = GlobalKey<PinPadState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (SchedulerBinding.instance.lifecycleState !=
          AppLifecycleState.paused) {
        _init();
      }
    });
  }

  Future<void> _init() async {
    final localAuth = LocalAuthentication();
    bool canAuthenticate = false;
    try {
      canAuthenticate =
          await localAuth.canCheckBiometrics ||
          await localAuth.isDeviceSupported();
    } catch (e) {
      debugPrint("Failed to check biometrics: $e");
    }
    if (!mounted) return;
    if (canAuthenticate) {
      _authBiometric();
    } else if (AuthStorage.hasPin) {
      setState(() {
        _usePin = true;
      });
    } else {
      widget.onSuccessfulAuth?.call();
    }
  }

  Future<void> _authBiometric() async {
    bool isAuthorized = false;
    try {
      isAuthorized = await LocalAuthentication().authenticate(
        localizedReason: "Please authenticate to continue".tl,
      );
    } catch (e) {
      debugPrint("Biometric auth error: $e");
      isAuthorized = false;
    }
    if (!mounted) return;
    if (isAuthorized) {
      widget.onSuccessfulAuth?.call();
      return;
    }
    if (AuthStorage.hasPin) {
      context.showMessage(message: "Authentication failed, try PIN".tl);
      setState(() {
        _usePin = true;
      });
    } else {
      context.showMessage(
        message: "Authentication failed, please try again".tl,
      );
    }
  }

  void _verifyPin(String pin) {
    if (AuthStorage.verifyPin(pin)) {
      widget.onSuccessfulAuth?.call();
    } else {
      context.showMessage(message: "Incorrect PIN".tl);
      _pinKey.currentState?.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Material(
        child: Center(
          child: _usePin
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: PinPad(
                    key: _pinKey,
                    title: "Enter PIN".tl,
                    showHelpButton: true,
                    onSubmit: _verifyPin,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.security, size: 36),
                    const SizedBox(height: 16),
                    Text("Authentication Required".tl),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _authBiometric,
                      child: Text("Continue".tl),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
