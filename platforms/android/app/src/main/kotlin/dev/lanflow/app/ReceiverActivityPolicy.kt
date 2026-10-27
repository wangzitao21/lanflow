package dev.lanflow.app

internal fun receiverNeedsForeground(enabled: Boolean, transferring: Boolean, paused: Boolean): Boolean =
    enabled && transferring && !paused
