package dev.lanflow.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/** A short multicast receive window, usable before the receiver service starts. */
internal class DiscoveryMulticastLock {
    private val window = DiscoveryWindow()
    private val handler = Handler(Looper.getMainLooper())
    private var lock: WifiManager.MulticastLock? = null
    private val finish = Runnable { refresh() }

    fun request(context: Context, durationMillis: Long) {
        if (durationMillis <= 0L) return
        if (lock == null) {
            try {
                val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                lock = wifi.createMulticastLock("lanflow:discovery").apply { setReferenceCounted(false) }
            } catch (_: Exception) { return /* Unicast/manual addressing still works. */ }
        }
        window.request(SystemClock.elapsedRealtime(), durationMillis)
        refresh()
    }

    private fun refresh() {
        handler.removeCallbacks(finish)
        val remaining = window.remaining(SystemClock.elapsedRealtime())
        if (remaining > 0L) {
            try {
                if (lock?.isHeld == false) lock?.acquire()
            } catch (_: Exception) { clear(); return }
            handler.postDelayed(finish, remaining)
        } else {
            clear()
        }
    }

    fun clear() {
        window.clear()
        handler.removeCallbacks(finish)
        try { if (lock?.isHeld == true) lock?.release() } catch (_: Exception) {}
    }
}
