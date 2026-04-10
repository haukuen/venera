import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

Future<String?> getProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") return appdata.settings['proxy'];

  String res;
  if (App.isLinux) {
    res = _getLinuxSystemProxy() ?? "No Proxy";
  } else {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return _normalizeProxy(proxy.substring(6));
      }
    }
  }
  return _normalizeProxy(res);
}

String? _getLinuxSystemProxy() {
  const keys = [
    'https_proxy',
    'HTTPS_PROXY',
    'all_proxy',
    'ALL_PROXY',
    'http_proxy',
    'HTTP_PROXY',
  ];

  for (var key in keys) {
    var value = Platform.environment[key];
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}

String? _normalizeProxy(String value) {
  var proxy = value.trim();
  if (proxy.isEmpty || proxy == "No Proxy") {
    return null;
  }

  if (proxy.contains("://")) {
    var uri = Uri.tryParse(proxy);
    if (uri == null || uri.host.isEmpty || !uri.hasPort) {
      return null;
    }

    var host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    var auth = '';
    if (uri.userInfo.isNotEmpty) {
      auth = '${uri.userInfo}@';
    }
    return '$auth$host:${uri.port}';
  }

  final regex = RegExp(
    r'^([^@:\s]+(?::[^@:\s]*)?@)?([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*|\[[0-9a-fA-F:]+\]):\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(proxy)) {
    return null;
  }

  return proxy;
}
