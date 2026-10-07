part of 'settings_page.dart';

class AppSettings extends StatefulWidget {
  const AppSettings({super.key});

  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  int _previousRetentionDays = 0;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("App".tl)),
        _SettingPartTitle(title: "Data".tl, icon: Icons.storage),
        ListTile(
          title: Text("Storage Path for local comics".tl),
          subtitle: Text(LocalManager().path, softWrap: false),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: LocalManager().path));
              context.showMessage(message: "Path copied to clipboard".tl);
            },
          ),
        ).toSliver(),
        _CallbackSetting(
          title: "Set New Storage Path".tl,
          actionTitle: "Set".tl,
          callback: () async {
            String? result;
            if (App.isAndroid) {
              var picker = DirectoryPicker();
              result = (await picker.pickDirectory())?.path;
            } else if (App.isIOS) {
              result = await selectDirectoryIOS();
            } else {
              result = await selectDirectory();
            }
            if (result == null) return;
            if (!App.rootContext.mounted) return;
            var loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            var res = await LocalManager().setNewPath(result);
            if (!App.rootContext.mounted) return;
            loadingDialog.close();
            if (res != null) {
              if (!context.mounted) return;
              context.showMessage(message: res);
            } else {
              if (!context.mounted) return;
              context.showMessage(message: "Path set successfully".tl);
              setState(() {});
            }
          },
        ).toSliver(),
        ListTile(
          title: Text("Cache Size".tl),
          subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
        ).toSliver(),
        _CallbackSetting(
          title: "Clear Cache".tl,
          actionTitle: "Clear".tl,
          callback: () async {
            var loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            await CacheManager().clear();
            loadingDialog.close();
            if (!context.mounted) return;
            context.showMessage(message: "Cache cleared".tl);
            setState(() {});
          },
        ).toSliver(),
        _SliderSetting(
          title: "Cache Limit".tl,
          settingsIndex: "cacheSize",
          interval: 256,
          min: 256,
          max: 8192,
          onChanged: () {
            CacheManager().setLimitSize(appdata.settings['cacheSize']);
          },
        ).toSliver(),
        _SliderSetting(
          title: "Auto Clear History".tl,
          subtitle: "0 means disabled".tl,
          settingsIndex: "historyRetentionDays",
          interval: 7,
          min: 0,
          max: 182,
          onChangeStart: (value) {
            _previousRetentionDays =
                (appdata.settings['historyRetentionDays'] as num).round();
          },
          onChangeEnd: () {
            final retentionDays =
                (appdata.settings['historyRetentionDays'] as num).round();
            // Require confirmation when lowering to a short retention window,
            // since this immediately deletes recent history.
            const confirmThreshold = 15;
            if (retentionDays > 0 &&
                retentionDays <= confirmThreshold &&
                retentionDays < _previousRetentionDays) {
              var confirmed = false;
              showConfirmDialog(
                context: App.rootContext,
                title: "Auto Clear History".tl,
                content: "Short retention warning".tl,
                confirmText: "Confirm",
                btnColor: context.colorScheme.error,
                onConfirm: () {
                  confirmed = true;
                  HistoryManager().clearExpiredHistory(retentionDays);
                },
              ).then((_) {
                if (!confirmed) {
                  // User dismissed without confirming: revert to the previous
                  // value so the destructive change is not applied.
                  appdata.settings['historyRetentionDays'] =
                      _previousRetentionDays;
                  appdata.saveData();
                  if (mounted) {
                    setState(() {});
                  }
                }
              });
              return;
            }
            if (retentionDays > 0) {
              HistoryManager().clearExpiredHistory(retentionDays);
            }
          },
        ).toSliver(),
        _CallbackSetting(
          title: "Export App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await exportAppData(false);
            await saveFile(filename: "data.venera", file: file);
            controller.close();
          },
          actionTitle: 'Export'.tl,
        ).toSliver(),
        SelectSetting(
          title: "Chapter Export Naming Format".tl,
          settingKey: "chapterExportNamingFormat",
          optionTranslation: const {
            "ep": "EP001",
            "chinese": "第001话",
            "volume": "v01",
            "number": "001",
          },
          help:
              "Naming format of the chapter segment in split-chapter export filenames, e.g. Title_第001话_Chapter.cbz"
                  .tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Import App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await selectFile(ext: ['venera', 'picadata']);
            if (file != null) {
              var cacheFile = File(
                FilePath.join(App.cachePath, "import_data_temp"),
              );
              await file.saveTo(cacheFile.path);
              try {
                if (file.name.endsWith('picadata')) {
                  await importPicaData(cacheFile);
                } else {
                  await importAppData(cacheFile, isLocalRestore: true);
                }
              } catch (e, s) {
                Log.error("Import data", e.toString(), s);
                if (!context.mounted) return;
                context.showMessage(message: "Failed to import data".tl);
              } finally {
                cacheFile.deleteIgnoreError();
                App.forceRebuild();
              }
            }
            controller.close();
          },
          actionTitle: 'Import'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Data Sync".tl,
          callback: () async {
            showPopUpWidget(context, const _WebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Comic Archive Backup".tl,
          callback: () async {
            showPopUpWidget(context, const _BackupWebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        _SettingPartTitle(title: "User".tl, icon: Icons.person_outline),
        SelectSetting(
          title: "Language".tl,
          settingKey: "language",
          optionTranslation: const {
            "system": "System",
            "zh-CN": "简体中文",
            "zh-TW": "繁體中文",
            "en-US": "English",
          },
          onChanged: () {
            App.forceRebuild();
          },
        ).toSliver(),
        SelectSetting(
          title: "Initial Page".tl,
          settingKey: "initialPage",
          optionTranslation: {
            '0': "Home Page".tl,
            '1': "Favorites Page".tl,
            '2': "Explore Page".tl,
            '3': "Categories Page".tl,
          },
        ).toSliver(),
        if (!App.isLinux)
          _SwitchSetting(
            title: "Authorization Required".tl,
            settingKey: "authorizationRequired",
            onChanged: () async {
              var current = appdata.settings['authorizationRequired'];
              if (current) {
                final auth = LocalAuthentication();
                bool canAuthenticate;
                try {
                  final bool canAuthenticateWithBiometrics =
                      await auth.canCheckBiometrics;
                  canAuthenticate =
                      canAuthenticateWithBiometrics ||
                      await auth.isDeviceSupported();
                } catch (_) {
                  canAuthenticate = false;
                }
                if (!canAuthenticate) {
                  if (!context.mounted) return;
                  await showPopUpWidget(context, const AuthPinSetting());
                  if (!context.mounted) return;
                  if (AuthStorage.pinHash == null) {
                    setState(() {
                      appdata.settings['authorizationRequired'] = false;
                    });
                    appdata.saveData();
                  }
                }
              }
              if (mounted) setState(() {});
            },
          ).toSliver(),
        if (!App.isLinux && appdata.settings['authorizationRequired'] == true)
          _CallbackSetting(
            title: "Use PIN to unlock".tl,
            actionTitle: AuthStorage.pinHash == null ? "Set".tl : "Change".tl,
            callback: () async {
              await showPopUpWidget(context, const AuthPinSetting());
              if (mounted) setState(() {});
            },
          ).toSliver(),
        SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String logLevelToShow = "all";

  @override
  Widget build(BuildContext context) {
    var logToShow = logLevelToShow == "all"
        ? Log.logs
        : Log.logs.where((log) => log.level.name == logLevelToShow).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Logs".tl),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              final RelativeRect position = RelativeRect.fromLTRB(
                MediaQuery.of(context).size.width,
                MediaQuery.of(context).padding.top + kToolbarHeight,
                0.0,
                0.0,
              );
              showMenu(
                context: context,
                position: position,
                items: [
                  PopupMenuItem(
                    child: Text("all"),
                    onTap: () => setState(() => logLevelToShow = "all"),
                  ),
                  PopupMenuItem(
                    child: Text("info"),
                    onTap: () => setState(() => logLevelToShow = "info"),
                  ),
                  PopupMenuItem(
                    child: Text("warning"),
                    onTap: () => setState(() => logLevelToShow = "warning"),
                  ),
                  PopupMenuItem(
                    child: Text("error"),
                    onTap: () => setState(() => logLevelToShow = "error"),
                  ),
                ],
              );
            }),
            icon: const Icon(Icons.filter_list_outlined),
          ),
          IconButton(
            onPressed: () => setState(() {
              final RelativeRect position = RelativeRect.fromLTRB(
                MediaQuery.of(context).size.width,
                MediaQuery.of(context).padding.top + kToolbarHeight,
                0.0,
                0.0,
              );
              showMenu(
                context: context,
                position: position,
                items: [
                  PopupMenuItem(
                    child: Text("Clear".tl),
                    onTap: () => setState(() => Log.clear()),
                  ),
                  PopupMenuItem(
                    child: Text("Disable Length Limitation".tl),
                    onTap: () {
                      Log.ignoreLimitation = true;
                      context.showMessage(
                        message: "Only valid for this run".tl,
                      );
                    },
                  ),
                  PopupMenuItem(
                    child: Text("Export".tl),
                    onTap: () => saveLog(Log().toString()),
                  ),
                ],
              );
            }),
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: ListView.builder(
        reverse: true,
        controller: ScrollController(),
        itemCount: logToShow.length,
        itemBuilder: (context, index) {
          index = logToShow.length - index - 1;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(AppRadius.xl),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(logToShow[index].title),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        decoration: BoxDecoration(
                          color: [
                            Theme.of(context).colorScheme.error,
                            Theme.of(context).colorScheme.errorContainer,
                            Theme.of(context).colorScheme.primaryContainer,
                          ][logToShow[index].level.index],
                          borderRadius: const BorderRadius.all(
                            Radius.circular(AppRadius.xl),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(
                            logToShow[index].level.name,
                            style: TextStyle(
                              color: logToShow[index].level.index == 0
                                  ? Colors.white
                                  : Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(logToShow[index].content),
                  Text(
                    logToShow[index].time.toString().replaceAll(
                      RegExp(r"\.\w+"),
                      "",
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: logToShow[index].content),
                      );
                    },
                    child: Text("Copy".tl),
                  ),
                  const Divider(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void saveLog(String log) async {
    saveFile(data: utf8.encode(log), filename: 'log.txt');
  }
}
