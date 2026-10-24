package dev.lanflow.app

import java.io.File
import java.nio.file.Files

fun main() {
    val root = Files.createTempDirectory("lanflow-share-recovery-").toFile().canonicalFile
    try {
        val folder = File(root, "interrupted").apply { mkdirs() }
        ShareRecovery.begin(folder, "保留分享文字", 2)
        ShareRecovery.plan(folder, 0, "完成.txt", "text/plain")
        File(folder, "0").mkdirs()
        File(folder, "0/完成.txt").writeText("flushed bytes")
        ShareRecovery.plan(folder, 1, "未完成.bin", "application/octet-stream")
        File(folder, "1").mkdirs()
        File(folder, "1/.copying").writeText("partial bytes")
        val partial = ShareRecovery.recover(folder)
        check(partial.text == "保留分享文字" && partial.missing == 1)
        check(partial.files.size == 1 && File(partial.files.single().path).readText() == "flushed bytes")
        // Death after the final file rename, before publishing payload.json.
        check(File(folder, "1/.copying").renameTo(File(folder, "1/未完成.bin")))
        val completed = ShareRecovery.recover(folder)
        check(completed.missing == 0 && completed.files.size == 2)
        val text = File(root, "text")
        ShareRecovery.begin(text, "only text", 0)
        check(ShareRecovery.recover(text).text == "only text")
        check(runCatching { ShareRecovery.plan(folder, 0, "../outside", "text/plain") }.isFailure)
        check(runCatching { ShareRecovery.plan(folder, 0, ".copying", "text/plain") }.isFailure)
        println("Share recovery: interrupted streams, completed files, text and unsafe paths passed")
    } finally {
        check(root.parentFile == File(System.getProperty("java.io.tmpdir")).canonicalFile)
        check(root.name.startsWith("lanflow-share-recovery-"))
        root.deleteRecursively()
    }
}
