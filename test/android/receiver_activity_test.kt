package dev.lanflow.app

fun main() {
    check(!receiverNeedsForeground(true, false, false)) { "Idle receivers must not keep a notification" }
    check(!receiverNeedsForeground(true, true, true)) { "Paused receivers must not keep a notification" }
    check(!receiverNeedsForeground(false, true, false)) { "Closed sessions cannot restart a notification" }
    check(receiverNeedsForeground(true, true, false)) { "Actual background transfers still need their service" }
    println("Receiver activity checks passed")
}
