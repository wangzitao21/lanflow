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
        private var enabled = false
        private var requestedActive = false
        private var application: Context? = null
        private val discoveryLock = DiscoveryMulticastLock()
        private val startup = Handler(Looper.getMainLooper())
        private val startTransfer = Runnable {
            val context = application
            if (context != null && shouldRun(context) && current == null) {
                try {
                    val intent = Intent(context, ReceiverService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                    else context.startService(intent)
                } catch (_: IllegalStateException) {
                    // Android may prohibit starting a service from a background
                    // process. The live connection continues; reopening retries.
                } catch (_: SecurityException) {
                    // Never block local storage or network recovery on a notification.
                }
            }
        }

        private fun shouldRun(context: Context): Boolean {
            val paused = context.getSharedPreferences("lanflow_receiver", Context.MODE_PRIVATE)
                .getBoolean("paused", false)
            return receiverNeedsForeground(enabled, requestedActive, paused)
        }

        private fun schedule(context: Context) {
            application = context.applicationContext
            startup.removeCallbacks(startTransfer)
            if (!shouldRun(context)) {
                current?.finishTransfer()
                context.stopService(Intent(context, ReceiverService::class.java))
                context.getSystemService(NotificationManager::class.java).cancel(1001)
            } else if (current == null) {
                // Short metadata exchanges never create a notification.
                startup.postDelayed(startTransfer, 1000L)
            }
        }

        fun enable(context: Context) {
            enabled = true
            schedule(context)
        }

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
                language?.let { service.english = it == "en" }
                paused?.let { service.paused = it }
                active?.let { service.transferring = it }
                service.refreshState()
            }
            schedule(context)
        }

        fun requestDiscoveryWindow(context: Context, durationMillis: Long) {
            if (context.getSharedPreferences("lanflow_receiver", Context.MODE_PRIVATE).getBoolean("paused", false)) return
            discoveryLock.request(context, durationMillis)
        }

        fun stop(context: Context) {
            enabled = false
            requestedActive = false
            startup.removeCallbacks(startTransfer)
            discoveryLock.clear()
            current?.finishTransfer()
            context.stopService(Intent(context, ReceiverService::class.java))
            context.getSystemService(NotificationManager::class.java).cancel(1001)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var transferring = false
    private var paused = false
    private var english = false
    private val handler = Handler(Looper.getMainLooper())
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (receiverNeedsForeground(enabled, transferring, paused)) {
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
        // Satisfy Android's foreground-service contract even if a transfer
        // completes between startForegroundService and service creation.
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1001, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else startForeground(1001, notification())
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lanflow:transfer").apply { setReferenceCounted(false) }
        refreshState()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        transferring = requestedActive
        refreshState()
        return START_NOT_STICKY
    }

    private fun updateChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel("lanflow_receive", if (english) "Message sync" else "消息同步", NotificationManager.IMPORTANCE_LOW)
            channel.setSound(null, null)
            channel.enableVibration(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun finishTransfer() {
        handler.removeCallbacks(renewWakeLock)
        if (wakeLock?.isHeld == true) wakeLock?.release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun refreshState() {
        handler.removeCallbacks(renewWakeLock)
        if (!receiverNeedsForeground(enabled, transferring, paused)) {
            finishTransfer()
            return
        }
        wakeLock?.acquire(5 * 60 * 1000L)
        handler.postDelayed(renewWakeLock, 60 * 1000L)
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
            .setContentText(if (english) "Transferring messages and files" else "正在传输消息和文件")
            .setContentIntent(launch).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false).build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) { stop(this) }
    override fun onDestroy() {
        handler.removeCallbacks(renewWakeLock)
        if (wakeLock?.isHeld == true) wakeLock?.release()
        if (current === this) {
            current = null
            if (enabled && requestedActive && !paused) schedule(this)
        }
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
