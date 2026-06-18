import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/translations.dart';

/// 原生后台下载控制器。
///
/// 在 Android 上，当至少存在一个进行中的下载任务时，启动前台服务
/// （含通知 + wakelock），避免锁屏或切后台时系统冻结 Dart isolate。
///
/// 在 iOS / 桌面端为 no-op：iOS 不允许 Flutter app 在后台持续运行，
/// 桌面端则不存在该限制。调用方无需自行做平台分支。
///
/// 真正的下载逻辑位于 `lib/network/download.dart`。本类仅负责操作系统
/// 层面"保持进程存活"这一件事。
class BackgroundDownload {
  BackgroundDownload._();

  static final BackgroundDownload instance = BackgroundDownload._();

  static const _channel = MethodChannel('venera/download_service');

  /// 上一次报告的前台服务运行状态。
  ///
  /// 仅记录我们自己的请求状态；OS 仍可能拆掉服务（例如用户从最近任务
  /// 列表划掉 app），这种情况会在下次回到前台时通过 [onAppResumed]
  /// 重新同步。
  bool _serviceRunning = false;

  /// 本 session 内是否已经申请过一次 POST_NOTIFICATIONS 权限。
  /// 避免每次开始下载都重新弹窗；如果用户已拒绝，后续申请会直接走
  /// 系统设置流程或静默降级。
  bool _permissionRequested = false;

  /// 1Hz 计时器：在前台服务运行期间，持续把当前下载进度推到通知。
  /// 没有它的话，通知文案只在队列结构变化时（增删任务等）才会更新，
  /// 切到后台后会一直停留在下载开始时的文本上。
  Timer? _progressTimer;

  /// 当前平台是否支持后台下载前台服务。目前仅 Android 支持。
  bool get isSupported => App.isAndroid;

  /// 将前台服务状态与当前下载队列重新同步。
  ///
  /// 在以下时机调用：队列结构变化（增删任务、完成等）或 app 回到前台
  /// （以防 OS 在后台期间杀掉了服务）。
  ///
  /// - 至少有一个运行中（非暂停）的任务 -> 启动服务并开始周期性推送进度。
  /// - 否则 -> 停止服务并取消进度计时器。
  Future<void> sync() async {
    if (!isSupported) return;

    final tasks = LocalManager().downloadingTasks;
    // 处于错误状态的任务已停止下载（不会产生数据流），不计入"运行中"，
    final runningTask = tasks
        .where((t) => !t.isPaused && !t.isError)
        .firstOrNull;

    if (runningTask == null) {
      if (_serviceRunning) {
        await _stop();
      }
      return;
    }

    // 立刻推送一次，让通知马上反映最新状态，然后再让计时器继续运行
    // （或启动它）。_pushProgress 会调用 _start，把 _serviceRunning 置为
    // true；如果服务已在运行，_start 只会刷新通知文案。
    await _pushProgress();
    if (_serviceRunning) {
      _ensureTimer();
    }
  }

  void _ensureTimer() {
    if (_progressTimer != null) return;
    // 1Hz 与任务自身的速度记录节奏一致，且对 platform channel 友好。
    // Android 本身也会合并频繁的通知更新，所以更快只是浪费。
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pushProgress();
    });
  }

  void _cancelTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  Future<void> _pushProgress() async {
    final tasks = LocalManager().downloadingTasks;
    final runningTask = tasks
        .where((t) => !t.isPaused && !t.isError)
        .firstOrNull;
    if (runningTask == null) {
      // 没有运行中的任务（全部完成/暂停/出错）-> 立刻停掉 timer，
      // 避免每秒空转。下一次队列状态变化会通过 sync() 重新启动。
      _cancelTimer();
      return;
    }
    final activeCount = tasks.where((t) => !t.isPaused && !t.isError).length;
    final text = _describe(
      runningTask.title,
      runningTask.message,
      activeCount,
      runningTask.progress,
    );
    await _start(text);
    if (!_serviceRunning) {
      // _start 失败（权限被拒 / 系统限制 / channel 缺失）-> 取消 timer，
      // 否则每秒都会重复发起无意义的 Platform Channel 调用
      _cancelTimer();
    }
  }

  /// app 回到前台时调用。重新同步前台服务，以防 OS 在后台期间杀掉了它。
  ///
  /// 注意：这里有意不去自动恢复"用户主动暂停"的任务。Android 上的前台
  /// 服务已经能让进行中的下载在后台继续，这是本特性的核心修复点；
  /// 被用户显式暂停的任务保持暂停，直到用户从 UI 上恢复。
  Future<void> onAppResumed() async {
    await sync();
  }

  /// 确保 Android 13+ 已授予 POST_NOTIFICATIONS 权限。幂等：本 session
  /// 内最多触发一次系统弹窗。后续调用只检查当前状态。
  ///
  /// 返回 true 表示前台服务可以显示通知。返回 false **不会阻断下载本身**，
  /// 仅表示在用户授权前，本设备无法获得后台保护。
  Future<bool> _ensureNotificationPermission() async {
    if (!isSupported) return true;
    try {
      final has = await _channel.invokeMethod<bool>(
        'hasNotificationPermission',
      );
      if (has == true) return true;
      if (_permissionRequested) return false;
      _permissionRequested = true;
      final granted = await _channel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      return granted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 较老的 Android 版本或非 Android 平台：无需此权限。
      return true;
    }
  }

  /// 公开包装：供希望预先 warm 权限的调用方使用（例如在用户开始第一次
  /// 下载前）。当前未使用，暴露出来以备将来。
  Future<bool> requestNotificationPermission() async {
    _permissionRequested = false;
    return _ensureNotificationPermission();
  }

  Future<void> _start(String text) async {
    // 在通知权限未授予时不启服务：否则 Android 12+ 在 app 后台时会抛
    // ForegroundServiceStartNotAllowedException。
    if (!await _ensureNotificationPermission()) {
      _serviceRunning = false;
      return;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('start', {'text': text});
      _serviceRunning = ok ?? false;
    } on PlatformException {
      // channel 缺失 / 服务启动被拒。优雅降级：前台下载仍可工作，
      // 只是失去后台保护。
      _serviceRunning = false;
    } on MissingPluginException {
      _serviceRunning = false;
    }
  }

  Future<void> _stop() async {
    _cancelTimer();
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    } finally {
      _serviceRunning = false;
    }
  }

  String _describe(
    String title,
    String message,
    int activeCount, [
    double progress = 0,
  ]) {
    final percent = (progress * 100).clamp(0, 100).round();
    final suffix = '$message ($percent%)';
    if (activeCount <= 1) {
      // message 在任务侧已经是本地化过的；这里只是拼接。
      return message.isNotEmpty ? '$title - $suffix' : title;
    }
    return '@a and @b more'.tlParams({
      'a': '$title - $suffix',
      'b': activeCount - 1,
    });
  }
}
