import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/headless/command_runner.dart';
import 'package:venera/headless/gui_session.dart';
import 'package:venera/headless/ipc.dart';
import 'package:venera/headless/runtime_lock.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/background_download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';
import 'components/components.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/app_page_route.dart';
import 'foundation/appdata.dart';
import 'headless.dart';
import 'init.dart';

void main(List<String> args) {
  if (args.contains('--headless')) {
    unawaited(_runHeadlessProcess(args));
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(
      () async {
        await _startGui();
      },
      (error, stack) {
        Log.error("Unhandled Exception", error, stack);
      },
    );
  });
}

CliIpcServer? _cliIpcServer;

Future<void> _runHeadlessProcess(List<String> args) async {
  var code = await runHeadlessMode(args);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}

Future<void> _startGui() async {
  WidgetsFlutterBinding.ensureInitialized();
  await App.init();
  if (!App.isDesktop) {
    await init();
    runApp(const MyApp());
    return;
  }

  var lease = await CliRuntimeLock.tryAcquire();
  if (lease == null) {
    runApp(
      _RuntimeConflictApp(
        onRetry: () async {
          var retryLease = await CliRuntimeLock.tryAcquire();
          if (retryLease == null) return false;
          await _launchDesktopGui(retryLease);
          return true;
        },
      ),
    );
    await _showConflictWindow();
    return;
  }
  await _launchDesktopGui(lease);
}

Future<void> _launchDesktopGui(CliRuntimeLease lease) async {
  try {
    await lease.clearStaleDescriptor();
    await windowManager.ensureInitialized();
    await init();
    var authorizationRequired =
        appdata.settings['authorizationRequired'] == true;
    CliGuiSession.instance.configure(
      authorizationRequired: authorizationRequired,
      authenticated: !authorizationRequired,
    );
    CliGuiSession.instance.registerUnlockRequester(_focusGui);
    _cliIpcServer = CliIpcServer(
      lease: lease,
      runner: CliCommandRunner(),
      authorize: CliGuiSession.instance.authorize,
    );
    await _cliIpcServer!.start(appVersion: App.version);
    runApp(const MyApp());
    await _prepareDesktopWindow();
  } catch (_) {
    await lease.release();
    rethrow;
  }
}

Future<void> _focusGui() async {
  if (!App.isDesktop) return;
  await windowManager.show();
  await windowManager.focus();
}

Future<void> _showConflictWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow();
  await windowManager.setMinimumSize(const Size(420, 260));
  await windowManager.show();
  await windowManager.focus();
}

Future<void> _prepareDesktopWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: App.isMacOS,
  );
  if (App.isLinux) {
    await windowManager.setBackgroundColor(Colors.transparent);
  }
  await windowManager.setMinimumSize(const Size(500, 600));
  var placement = await WindowPlacement.loadFromFile();
  if (App.isLinux) {
    await windowManager.show();
    await placement.applyToWindow();
  } else {
    await placement.applyToWindow();
    await windowManager.show();
  }
  WindowPlacement.loop();
}

class _RuntimeConflictApp extends StatefulWidget {
  const _RuntimeConflictApp({required this.onRetry});

  final Future<bool> Function() onRetry;

  @override
  State<_RuntimeConflictApp> createState() => _RuntimeConflictAppState();
}

class _RuntimeConflictAppState extends State<_RuntimeConflictApp> {
  bool retrying = false;
  String? message;

  Future<void> retry() async {
    if (retrying) return;
    setState(() {
      retrying = true;
      message = null;
    });
    try {
      if (!await widget.onRetry() && mounted) {
        setState(() => message = 'The profile is still in use.');
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Another Venera process is using this profile.',
                  textAlign: TextAlign.center,
                ),
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Text(message!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(
                      onPressed: retrying ? null : retry,
                      child: Text(retrying ? 'Retrying…' : 'Retry'),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: () => windowManager.close(),
                      child: const Text('Quit'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    App.registerForceRebuild(forceRebuild);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    CliGuiSession.instance.registerUnlockRequester(_requestCliUnlock);
    checkUpdates();
    if (App.isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkClipboardForVeneraLink();
      });
    }
    super.initState();
  }

  @override
  void dispose() {
    CliGuiSession.instance.registerUnlockRequester(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool isAuthPageActive = false;
  bool _sessionAuthenticated = false;

  OverlayEntry? hideContentOverlay;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached && App.isDesktop) {
      var server = _cliIpcServer;
      _cliIpcServer = null;
      if (server != null) unawaited(server.close());
    }
    if (state == AppLifecycleState.resumed && App.isMobile) {
      _checkClipboardForVeneraLink();
      // 重新同步后台下载前台服务：OS 可能在后台期间杀掉了它。
      // 在不支持的平台上（iOS / 桌面）为 no-op。
      BackgroundDownload.instance.onAppResumed();
    }
    if (!App.isMobile || !appdata.settings['authorizationRequired']) {
      super.didChangeAppLifecycleState(state);
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: App.rootContext.colorScheme.surface,
            ),
          );
        },
      );
      Overlay.of(App.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !isAuthPageActive &&
        !IO.isSelectingFiles) {
      _sessionAuthenticated = false;
      CliGuiSession.instance.markAuthenticated(false);
      isAuthPageActive = true;
      App.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            _sessionAuthenticated = true;
            CliGuiSession.instance.markAuthenticated(true);
            App.rootContext.pop();
            isAuthPageActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  Future<void> _requestCliUnlock() async {
    await _focusGui();
    if (!mounted || appdata.settings['authorizationRequired'] != true) return;
    setState(() {});
  }

  void _checkClipboardForVeneraLink() async {
    try {
      String? text;

      if (Platform.isIOS) {
        // On iOS, use native method to check and read clipboard in one call.
        // This avoids triggering the system paste notification for non-venera URLs.
        text = await const MethodChannel(
          'venera/method_channel',
        ).invokeMethod<String>('getVeneraClipboardLink');
        if (text == null) return;
      } else {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (data?.text == null) return;
        text = data!.text!;
      }

      final uri = parseVeneraLink(text);
      if (uri == null) return;

      final lastHandled =
          appdata.implicitData['lastHandledClipboard'] as String?;
      if (uri.toString() == lastHandled) return;
      appdata.implicitData['lastHandledClipboard'] = uri.toString();
      await appdata.writeImplicitData();

      final comic = parseComicFromUri(uri);
      if (comic == null) return;

      if (_isViewingComic(comic.id, comic.sourceKey)) return;

      // Extract title from the text line before the URL
      final uriMatch = RegExp(r'venera://\S+').firstMatch(text);
      final beforeUrl = text.substring(0, uriMatch?.start ?? 0).trim();
      final title = beforeUrl.isNotEmpty ? beforeUrl : null;

      final source = ComicSource.find(comic.sourceKey);
      final context = App.rootContext;
      if (!context.mounted) return;

      final displayName = title ?? comic.id;
      if (source != null) {
        showConfirmDialog(
          context: context,
          title: 'Open comic'.tl,
          content: '${'Open comic'.tl}: $displayName',
          onConfirm: () {
            App.mainNavigatorKey?.currentContext?.to(() {
              return ComicPage(id: comic.id, sourceKey: comic.sourceKey);
            });
          },
        );
      }
    } catch (e) {
      Log.warning("App", "Failed to handle clipboard link: $e");
    }
  }

  bool _isViewingComic(String id, String sourceKey) {
    final navContext = App.mainNavigatorKey?.currentContext;
    if (navContext == null) return false;
    ComicPage? found;
    void visitor(Element el) {
      if (found != null) return;
      if (el.widget is ComicPage) {
        found = el.widget as ComicPage;
        return;
      }
      el.visitChildren(visitor);
    }

    (navContext as Element).visitChildren(visitor);
    return found?.id == id && found?.sourceKey == sourceKey;
  }

  void forceRebuild() {
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  Color translateColorSetting() {
    return switch (appdata.settings['color']) {
      'red' => Colors.red,
      'pink' => Colors.pink,
      'purple' => Colors.purple,
      'green' => Colors.green,
      'orange' => Colors.orange,
      'blue' => Colors.blue,
      'yellow' => Colors.yellow,
      'cyan' => Colors.cyan,
      _ => Colors.blue,
    };
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness,
  ) {
    String? font;
    List<String>? fallback;
    if (App.isLinux || App.isWindows) {
      font = 'Noto Sans CJK';
      fallback = [
        'Segoe UI',
        'Noto Sans SC',
        'Noto Sans TC',
        'Noto Sans',
        'Microsoft YaHei',
        'PingFang SC',
        'Arial',
        'sans-serif',
      ];
    }
    return ThemeData(
      colorScheme: SeedColorScheme.fromSeeds(
        primaryKey: primary,
        secondaryKey: secondary,
        tertiaryKey: tertiary,
        brightness: brightness,
        tones: FlexTones.vividBackground(brightness),
      ),
      fontFamily: font,
      fontFamilyFallback: fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    var authorizationRequired =
        appdata.settings['authorizationRequired'] == true;
    CliGuiSession.instance.configure(
      authorizationRequired: authorizationRequired,
      authenticated: _sessionAuthenticated,
    );
    Widget home;
    if (authorizationRequired) {
      // AuthPage 不是直接作为 home，而是通过 Builder 延迟 push，
      // 确保 Navigator 从子树内部执行 push/pop，冷启动时过渡动画正常。
      home = Builder(
        builder: (context) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_sessionAuthenticated || isAuthPageActive) return;
            isAuthPageActive = true;
            Navigator.of(context).push(
              AppPageRoute(
                builder: (_) => AuthPage(
                  onSuccessfulAuth: () {
                    _sessionAuthenticated = true;
                    CliGuiSession.instance.markAuthenticated(true);
                    Navigator.of(context).pop();
                    isAuthPageActive = false;
                    forceRebuild();
                  },
                ),
              ),
            );
          });
          return Stack(
            children: [
              const MainPage(),
              if (!_sessionAuthenticated)
                Positioned.fill(
                  child: Container(
                    color: Theme.of(context).colorScheme.surface,
                  ),
                ),
            ],
          );
        },
      );
    } else {
      home = const MainPage();
    }
    return DynamicColorBuilder(
      builder: (light, dark) {
        Color? primary, secondary, tertiary;
        if (appdata.settings['color'] != 'system' ||
            light == null ||
            dark == null) {
          primary = translateColorSetting();
        } else {
          primary = light.primary;
          secondary = light.secondary;
          tertiary = light.tertiary;
        }
        return MaterialApp(
          title: "venera",
          home: home,
          debugShowCheckedModeBanner: false,
          theme: getTheme(primary, secondary, tertiary, Brightness.light),
          navigatorKey: App.rootNavigatorKey,
          darkTheme: getTheme(primary, secondary, tertiary, Brightness.dark),
          themeMode: switch (appdata.settings['theme_mode']) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          color: Colors.transparent,
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: () {
            var lang = appdata.settings['language'];
            if (lang == 'system') {
              return null;
            }
            return switch (lang) {
              'zh-CN' => const Locale('zh', 'CN'),
              'zh-TW' => const Locale('zh', 'TW'),
              'en-US' => const Locale('en'),
              _ => null,
            };
          }(),
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en'),
          ],
          builder: (context, widget) {
            ErrorWidget.builder = (details) {
              Log.error(
                "Unhandled Exception",
                "${details.exception}\n${details.stack}",
              );
              return Material(
                child: Center(child: Text(details.exception.toString())),
              );
            };
            if (widget != null) {
              /// 如果无法检测到状态栏高度设定指定高度
              /// https://github.com/flutter/flutter/issues/161086
              var isPaddingCheckError =
                  MediaQuery.of(context).viewPadding.top <= 0 ||
                  MediaQuery.of(context).viewPadding.top > 200;

              if (isPaddingCheckError && Platform.isAndroid) {
                widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(top: 15, bottom: 15),
                    padding: const EdgeInsets.only(top: 15, bottom: 15),
                  ),
                  child: widget,
                );
              }

              widget = OverlayWidget(widget);
              if (App.isDesktop) {
                widget = Shortcuts(
                  shortcuts: {
                    LogicalKeySet(LogicalKeyboardKey.escape):
                        VoidCallbackIntent(App.pop),
                  },
                  child: MouseBackDetector(
                    onTapDown: App.pop,
                    child: WindowFrame(widget),
                  ),
                );
              }
              return _SystemUiProvider(
                Material(
                  color: App.isLinux ? Colors.transparent : null,
                  child: widget,
                ),
              );
            }
            throw ('widget is null');
          },
        );
      },
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
