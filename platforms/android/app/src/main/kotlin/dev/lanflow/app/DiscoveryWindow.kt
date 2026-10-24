package dev.lanflow.app

/** One bounded discovery window, shared with requests made before service startup. */
internal class DiscoveryWindow {
    private var deadlineMillis = 0L

    fun request(nowMillis: Long, durationMillis: Long) {
        if (durationMillis <= 0L) return
        deadlineMillis = maxOf(deadlineMillis, nowMillis + durationMillis.coerceAtMost(15_000L))
    }

    fun remaining(nowMillis: Long): Long = (deadlineMillis - nowMillis).coerceAtLeast(0L)

    fun clear() {
        deadlineMillis = 0L
    }
}
