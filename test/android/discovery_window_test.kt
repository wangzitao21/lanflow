package dev.lanflow.app

fun main() {
    val window = DiscoveryWindow()
    check(window.remaining(1000L) == 0L)
    window.request(1000L, 5000L)
    check(window.remaining(1000L) == 5000L)
    check(window.remaining(6000L) == 0L)
    // A later, shorter request must not end an in-flight peer's response window.
    window.request(10_000L, 10_000L)
    window.request(11_000L, 1000L)
    check(window.remaining(11_000L) == 9000L)
    // Renewal extends one deadline; no periodic timers are needed while idle.
    window.request(19_000L, 5000L)
    check(window.remaining(20_000L) == 4000L)
    window.clear()
    check(window.remaining(20_000L) == 0L)
    // Even erroneous callers cannot acquire an unbounded discovery window.
    window.request(30_000L, Long.MAX_VALUE)
    check(window.remaining(30_000L) == 15_000L)
    window.clear()
    window.request(40_000L, 0L)
    window.request(40_000L, -1L)
    check(window.remaining(40_000L) == 0L)
    println("Discovery window: expiry, renewal, bounds and pause/exit cleanup passed")
}
