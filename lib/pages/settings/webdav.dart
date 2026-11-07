part of 'package:venera/pages/settings/settings_page.dart';

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting();

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";

  bool autoSync = true;

  bool isTesting = false;
  bool upload = true;
  bool syncAuthEnabled = true;

  @override
  void initState() {
    super.initState();
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.whereType<String>().length != 3) {
      return;
    }
    url = configs[0];
    user = configs[1];
    pass = configs[2];
    autoSync = appdata.implicitData['webdavAutoSync'] ?? true;
    syncAuthEnabled = appdata.implicitData['syncAuthEnabled'] ?? true;
  }

  void onAutoSyncChanged(bool value) {
    setState(() {
      autoSync = value;
      appdata.implicitData['webdavAutoSync'] = value;
      appdata.writeImplicitData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Webdav",
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "URL",
                hintText: "A valid WebDav directory URL".tl,
                border: OutlineInputBorder(),
              ),
              controller: TextEditingController(text: url),
              onChanged: (value) => url = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: user),
              onChanged: (value) => user = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: pass),
              onChanged: (value) => pass = value,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Auto Sync Data".tl),
              contentPadding: EdgeInsets.zero,
              trailing: Switch(value: autoSync, onChanged: onAutoSyncChanged),
            ),
            ListTile(
              leading: Icon(Icons.account_circle_outlined),
              title: Text("同步登录状态"),
              contentPadding: EdgeInsets.zero,
              trailing: Switch(
                value: syncAuthEnabled,
                onChanged: (value) async {
                  setState(() {
                    syncAuthEnabled = value;
                  });
                  await DataSync.setAuthSyncEnabled(value);
                },
              ),
            ),
            const SizedBox(height: 12),
            RadioGroup<bool>(
              groupValue: upload,
              onChanged: (value) {
                setState(() {
                  upload = value ?? upload;
                });
              },
              child: Row(
                children: [
                  Text("Operation".tl),
                  Radio<bool>(value: true),
                  Text("Upload".tl),
                  Radio<bool>(value: false),
                  Text("Download".tl),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: autoSync
                  ? Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Once the operation is successful, app will automatically sync data with the server."
                                  .tl,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    isLoading: isTesting,
                    onPressed: () async {
                      if (isTesting) return;
                      var oldConfig = appdata.settings['webdav'];
                      var oldAutoSync = appdata.implicitData['webdavAutoSync'];

                      if (url.trim().isEmpty &&
                          user.trim().isEmpty &&
                          pass.trim().isEmpty) {
                        appdata.settings['webdav'] = [];
                        appdata.implicitData['webdavAutoSync'] = false;
                        appdata.writeImplicitData();
                        appdata.saveData();
                        context.showMessage(message: "Saved".tl);
                        App.rootPop();
                        return;
                      }

                      appdata.settings['webdav'] = [url, user, pass];
                      appdata.implicitData['webdavAutoSync'] = autoSync;
                      appdata.writeImplicitData();

                      if (!autoSync) {
                        appdata.saveData();
                        context.showMessage(message: "Saved".tl);
                        App.rootPop();
                        return;
                      }

                      setState(() {
                        isTesting = true;
                      });
                      var testResult = upload
                          ? await DataSync().uploadDataManually()
                          : await DataSync().downloadDataManually();
                      if (!mounted) return;
                      setState(() {
                        isTesting = false;
                      });
                      if (testResult.error) {
                        appdata.settings['webdav'] = oldConfig;
                        appdata.implicitData['webdavAutoSync'] = oldAutoSync;
                        appdata.writeImplicitData();
                        appdata.saveData();
                        if (!context.mounted) return;
                        context.showMessage(message: testResult.errorMessage!);
                        context.showMessage(message: "Saved Failed".tl);
                      } else {
                        appdata.saveData();
                        if (!context.mounted) return;
                        context.showMessage(message: "Saved".tl);
                        App.rootPop();
                      }
                    },
                    child: Text("Continue".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    onPressed: _openDiagnostics,
                    child: const Text("同步诊断"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Button.outlined(
                    onPressed: _openDevices,
                    child: const Text("设备管理"),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  Future<void> _openDiagnostics() async {
    final data = await DataSync.syncDiagnostics();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: "同步诊断",
        content: SingleChildScrollView(
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(data),
          ),
        ).paddingHorizontal(16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("OK".tl),
          ),
        ],
      ),
    );
  }

  Future<void> _openDevices() async {
    await showDialog(
      context: context,
      builder: (_) => const _SyncDevicesDialog(),
    );
  }

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await DataSync().testConnection([url, user, pass]);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }
}

class _BackupWebdavSetting extends StatefulWidget {
  const _BackupWebdavSetting();

  @override
  State<_BackupWebdavSetting> createState() => _BackupWebdavSettingState();
}

class _BackupWebdavSettingState extends State<_BackupWebdavSetting> {
  late final TextEditingController _urlController;
  late final TextEditingController _userController;
  late final TextEditingController _passController;
  late final TextEditingController _remotePathController;
  bool syncEnabled = false;
  bool isTesting = false;

  @override
  void initState() {
    super.initState();
    final config = BackupConfig.fromSettings();
    _urlController = TextEditingController(text: config.url);
    _userController = TextEditingController(text: config.user);
    _passController = TextEditingController(text: config.pass);
    _remotePathController = TextEditingController(text: config.remotePath);
    syncEnabled = appdata.settings['backupWebdavSyncEnabled'] == true;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _remotePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Comic Archive Backup".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "URL",
                hintText: "A valid WebDav directory URL".tl,
                border: OutlineInputBorder(),
              ),
              controller: _urlController,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
              ),
              controller: _userController,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
              ),
              controller: _passController,
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Remote Path".tl,
                hintText: "/venera_backup/",
                border: const OutlineInputBorder(),
              ),
              controller: _remotePathController,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "This is only used for CBZ archive backup and restore."
                          .tl,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Sync archive config".tl),
              subtitle: Text(
                "Sync archive WebDAV URL, username, password and remote path with app data."
                    .tl,
              ),
              trailing: Switch(
                value: syncEnabled,
                onChanged: (v) {
                  setState(() {
                    syncEnabled = v;
                  });
                },
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    isLoading: isTesting,
                    onPressed: save,
                    child: Text("Continue".tl),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  BackupConfig get currentConfig => BackupConfig(
    url: _urlController.text,
    user: _userController.text,
    pass: _passController.text,
    remotePath: _remotePathController.text,
  );

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }

  Future<void> save() async {
    if (isTesting) return;
    appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
    final config = currentConfig;
    if (!config.isValid && config.user.trim().isEmpty && config.pass.isEmpty) {
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
      return;
    }
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(config);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      context.showMessage(message: "Saved Failed".tl);
    } else {
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
    }
  }
}

class _SyncDevicesDialog extends StatefulWidget {
  const _SyncDevicesDialog();

  @override
  State<_SyncDevicesDialog> createState() => _SyncDevicesDialogState();
}

class _SyncDevicesDialogState extends State<_SyncDevicesDialog> {
  late Future<List<Map<String, Object?>>> _future;

  @override
  void initState() {
    super.initState();
    _future = DataSync.syncDevices();
  }

  void _reload() {
    setState(() {
      _future = DataSync.syncDevices();
    });
  }

  void _remove(String deviceId) {
    showConfirmDialog(
      context: context,
      title: "Remove Device".tl,
      content:
          "Delete device @d from the sync server? Changes not yet synced to other devices will be lost."
              .tlParams({'d': deviceId}),
      onConfirm: () => _removeDevice(deviceId),
    );
  }

  Future<void> _removeDevice(String deviceId) async {
    final result = await DataSync.removeSyncDevice(deviceId);
    if (!mounted) return;
    if (result.error) {
      context.showMessage(message: result.errorMessage ?? 'Error');
    } else {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "设备管理",
      content: SizedBox(
        width: 480,
        child: FutureBuilder<List<Map<String, Object?>>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final devices = snapshot.data!;
            if (devices.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text("No devices".tl),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final device in devices)
                  if (device['error'] != null)
                    ListTile(title: Text(device['error'].toString()))
                  else
                    ListTile(
                      leading: Icon(
                        device['isSelf'] == true
                            ? Icons.smartphone
                            : Icons.devices,
                      ),
                      title: Text(device['deviceId'] as String),
                      subtitle: Text(
                        'lastChange: ${device['lastChange']} · '
                        '${device['lastSeen'] ?? ''}',
                      ),
                      trailing: device['isSelf'] == true
                          ? Text("This device".tl)
                          : IconButton(
                              tooltip: "Remove".tl,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  _remove(device['deviceId'] as String),
                            ),
                    ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("OK".tl),
        ),
      ],
    );
  }
}
