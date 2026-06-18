package io.github.haukuen.venera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * 前台服务：当至少存在一个进行中的下载任务时，保持 app 进程存活。
 * 否则 Android（Doze / app standby）会在锁屏或切后台后很快冻结 Dart
 * isolate，导致下载无声地停滞。
 *
 * 真正的下载逻辑完全在 Dart 侧（lib/network/download.dart）执行；本服务
 * 仅持有一条前台通知 + 一个 partial wakelock，让系统不要去打扰这个进程。
 *
 * 生命周期：
 *   - startService(ctx, contentText) -> 启动（幂等），同时刷新文本
 *   - stopService(ctx)               -> 停止（幂等）
 *
 * 通知使用低优先级 channel，不会发出提示音。
 */
class DownloadService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        // 在 onCreate 中一次性创建通知渠道。Service 生命周期内 onCreate 只
        // 调用一次，避免 onStartCommand / 通知刷新时重复的 IPC 开销。
        ensureChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: defaultText()
        // startForeground 必须在 startForegroundService 后 5 秒内调用。
        // 如果服务已经在运行，再次调用只会刷新通知。
        startForegroundCompat(text)
        // 获取 partial wakelock，让屏幕熄灭时 CPU 仍能继续运行。
        // 仅在服务存活期间持有。
        acquireWakelock()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakelock()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 用户从最近任务列表划掉了 app -> 没有理由继续运行。
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun startForegroundCompat(text: String) {
        // ensureChannel 已在 onCreate 中调用，此处无需重复。
        startForeground(
            NOTIFICATION_ID,
            buildNotification(text),
            // Android 10+ 要求 foregroundServiceType 与 manifest 声明匹配。
            // "dataSync" 覆盖用户主动发起的下载场景。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
        )
    }

    private fun buildNotification(text: String): Notification {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            // 总是创建 channel。对于已存在的 channel，重新 create 对
            // importance 等"不可变"属性是 no-op，但会更新用户可见的 name 和
            // description。否则装过老版本（英文文案）的设备会永远停留在
            // 系统通知设置里的旧英文名。
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.download_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.download_channel_desc)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun defaultText(): String = getString(R.string.download_notification_default)

    private fun acquireWakelock() {
        if (wakeLock != null) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "venera:download"
        ).apply {
            // 不设超时：wakelock 的生命周期由服务本身约束。
            // 在 onDestroy / stopService 中释放。
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakelock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    companion object {
        private const val NOTIFICATION_ID = 43520 // 0xAA00
        private const val CHANNEL_ID = "venera_download"
        private const val EXTRA_TEXT = "text"

        /**
         * 启动服务，或在服务已运行时刷新其通知文本。可重复调用。
         * 调用本方法是让 app 进程脱离 Doze / 冻结状态的关键。
         */
        fun startService(context: Context, text: String) {
            val intent = Intent(context, DownloadService::class.java).apply {
                putExtra(EXTRA_TEXT, text)
            }
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        }

        /**
         * 如果服务正在运行则停止它。服务未运行时调用也是安全的。
         */
        fun stopService(context: Context) {
            context.stopService(Intent(context, DownloadService::class.java))
        }
    }
}
