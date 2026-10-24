package dev.lanflow.app

import java.io.File
import java.util.Properties

/** A durable journal is written before copying bytes. A final filename means
 * its stream was flushed and atomically renamed; .copying is never recovered. */
internal object ShareRecovery {
    data class SavedFile(val path: String, val name: String, val mimeType: String)
    data class Recovered(val text: String, val files: List<SavedFile>, val missing: Int)
    private const val journal = ".import-state"

    fun exists(folder: File) = File(folder, journal).isFile

    fun begin(folder: File, text: String, count: Int) {
        require(text.length <= 20000 && count in 0..100)
        folder.mkdirs()
        save(folder, Properties().apply {
            setProperty("text", text)
            setProperty("count", count.toString())
        })
    }

    fun plan(folder: File, index: Int, name: String, mimeType: String) {
        require(safeName(name))
        val state = read(folder)
        require(index in 0 until state.getProperty("count").toInt())
        state.setProperty("file.$index.name", name)
        state.setProperty("file.$index.type", mimeType)
        save(folder, state)
    }

    fun recover(folder: File): Recovered {
        val state = read(folder)
        val text = state.getProperty("text", "")
        val count = state.getProperty("count").toInt()
        require(text.length <= 20000 && count in 0..100)
        val boundary = folder.canonicalFile
        val files = mutableListOf<SavedFile>()
        for (index in 0 until count) {
            val name = state.getProperty("file.$index.name") ?: break
            require(safeName(name))
            val file = File(File(folder, index.toString()), name)
            require(file.canonicalFile.parentFile?.parentFile == boundary)
            if (!file.isFile) break
            files.add(SavedFile(file.absolutePath, name,
                state.getProperty("file.$index.type", "application/octet-stream")))
        }
        return Recovered(text, files, count - files.size)
    }

    private fun safeName(name: String) = name.isNotBlank() &&
        name !in setOf(".", "..", ".copying") && !name.contains('/') &&
        !name.contains('\\') && !name.contains('\u0000')

    private fun read(folder: File) = Properties().apply {
        File(folder, journal).inputStream().use { load(it) }
    }

    private fun save(folder: File, state: Properties) {
        val pending = File(folder, "$journal.pending")
        pending.outputStream().use { output ->
            state.store(output, null)
            output.fd.sync()
        }
        require(pending.renameTo(File(folder, journal))) { "无法保存分享进度" }
    }
}
