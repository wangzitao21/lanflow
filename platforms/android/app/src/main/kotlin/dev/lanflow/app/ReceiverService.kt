package dev.lanflow.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.Handler
import android.os.Looper

class ReceiverService : Service() {
    companion object {
        private var current: ReceiverService? = null
        private var requestedActive = false
        private val discoveryLock = DiscoveryMulticastLock()

        fun updateState(context: Context, language: String? = null, paused: Boolean? = null, active: Boolean? = null) {
            active?.let { requestedActive = it }
            if (paused == true) discoveryLock.clear()
            if (language != null || paused != null) {
                context.getSharedPreferences("lanflow_receiver", Context.MODE_PRIVATE).edit().apply {
                    language?.let { putString("language", it) }
                    paused?.let { putBoolean("paused", it) }
                }.apply()
            }
            current?.let { service ->
                val changed = (language != null && service.english != (language == "en")) ||
                    (paused != null && service.paused != paused) ||
                    (active != null && service.transferring != active)
                language?.let { service.english = it == "en" }
                paused?.let { service.paused = it }
                active?.let { service.transferring = it }
                if (changed) service.refreshState()
            }
        }

        fun requestDiscoveryWindow(context: Context, durationMillis: Long) {
            val paused = current?.paused ?: context.getSharedPreferences("lanflow_receiver", Context.MODE_PRIVATE)
                .getBoolean("paused", false)
            if (paused) return
            discoveryLock.request(context, durationMillis)
        }

        fun stop(context: Context) {
            requestedActive = false
            discoveryLock.clear()
            context.stopService(Intent(context, ReceiverService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var transferring = false
    private var paused = false
    private var english = false
    private val handler = Handler(Looper.getMainLooper())
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (transferring && !paused) {
                // Keep each acquisition bounded, but renew while real work
                // remains. Long transfers must not lose their lock at 2 hours.
                wakeLock?.acquire(5 * 60 * 1000L)
                handler.postDelayed(this, 60 * 1000L)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val preferences = getSharedPreferences("lanflow_receiver", MODE_PRIVATE)
        english = preferences.getString("language", "zh") == "en"
        paused = preferences.getBoolean("paused", false)
        transferring = requestedActive
        current = this
        updateChannel()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1001, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else startForeground(1001, notification())
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lanflow:transfer").apply { setReferenceCounted(false) }
        refreshState()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.hasExtra("transferring") == true) {
            transferring = intent.getBooleanExtra("transferring", false)
        }
        refreshState()
        return START_NOT_STICKY
    }

    private fun updateChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("lanflow_receive", if (english) "Message sync" else "消息同步", NotificationManager.IMPORTANCE_LOW))
        }
    }

    private fun refreshState() {
        val active = transferring && !paused
        if (paused) discoveryLock.clear()
        handler.removeCallbacks(renewWakeLock)
        if (active) {
            wakeLock?.acquire(5 * 60 * 1000L)
            handler.postDelayed(renewWakeLock, 60 * 1000L)
        }
        if (!active && wakeLock?.isHeld == true) wakeLock?.release()
        updateChannel()
        getSystemService(NotificationManager::class.java).notify(1001, notification())
    }

    private fun notification(): Notification {
        val launch = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "lanflow_receive")
            else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder.setSmallIcon(R.drawable.ic_transfer)
            .setContentTitle("LanFlow")
            .setContentText(when {
                paused -> if (english) "Sync paused · Tap to open" else "同步已暂停，轻点打开"
                transferring -> if (english) "Syncing messages and files" else "正在同步消息和文件"
                else -> if (english) "Background sync ready · Tap to open" else "后台同步服务已就绪，轻点打开"
            })
            .setContentIntent(launch).setOngoing(true).setShowWhen(false).build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) { stopSelf() }
    override fun onDestroy() {
        handler.removeCallbacks(renewWakeLock)
        if (current === this) { current = null; requestedActive = false; discoveryLock.clear() }
        if (wakeLock?.isHeld == true) wakeLock?.release()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
