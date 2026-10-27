package dev.lanflow.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.content.ContentValues
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.text.Collator
import java.util.Locale
import java.io.File
import java.net.URLConnection
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.lang.ref.WeakReference
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private class ShareCancelled : Exception()
    private class ShareJob(val id: String, val fileCount: Int) {
        @Volatile var cancelled = false
        @Volatile var input: java.io.InputStream? = null
        var committing = false
        @Volatile var progress: Map<String, Any> = mapOf(
            "id" to id, "name" to "", "fileIndex" to 0, "fileCount" to fileCount,
            "bytes" to 0L, "phase" to "queued")
    }
    companion object {
        private val shareWorker = Executors.newSingleThreadExecutor()
        private val controlWorker = Executors.newSingleThreadExecutor()
        private val exportWorker = Executors.newSingleThreadExecutor()
        private val shareJobs = ConcurrentHashMap<String, ShareJob>()
        private val shareStateLock = Any()
        @Volatile private var activeActivity: WeakReference<MainActivity>? = null
    }
    private var exportResult: MethodChannel.Result? = null
    private var exportSource: File? = null
    private var channel: MethodChannel? = null
    private var collationChannel: MethodChannel? = null
    private var currentShareId: String? = null
    private val networkMonitor by lazy {
        NetworkStateMonitor(this) { state, availabilityChanged ->
            channel?.invokeMethod("networkStateChanged", state)
            if (availabilityChanged) channel?.invokeMethod("networkChanged", state["available"])
        }
    }

    override fun popSystemNavigator(): Boolean {
        // Returning from the main conversation keeps the sync engine alive.
        // Flutter still closes its own image viewer and dialogs first.
        moveTaskToBack(true)
        return true
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activeActivity = WeakReference(this)
        captureShare(intent, savedInstanceState?.getString("lanflow.shareId"))
        networkMonitor.start()
    }

    private fun publishProgress(job: ShareJob, phase: String, name: String = "", index: Int = 0, bytes: Long = 0, total: Long? = null) {
        val progress = synchronized(job) {
            if (phase in setOf("queued", "copying") && job.cancelled) return
            val update = mutableMapOf<String, Any>("id" to job.id, "phase" to phase,
                "name" to name, "fileIndex" to index, "fileCount" to job.fileCount, "bytes" to bytes)
            if (total != null && total >= 0) update["totalBytes"] = total
            job.progress = update
            update
        }
        activeActivity?.get()?.let { activity ->
            activity.runOnUiThread {
                // A queued copying event must not revive a cancelled/ready job.
                if (job.progress === progress) activity.channel?.invokeMethod("shareProgress", progress)
            }
        }
    }

    private fun notifySharesChanged() {
        activeActivity?.get()?.let { activity ->
            activity.runOnUiThread { activity.channel?.invokeMethod("sharesChanged", null) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShare(intent, null)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        currentShareId?.let { outState.putString("lanflow.shareId", it) }
        super.onSaveInstanceState(outState)
    }

    @Suppress("DEPRECATION")
    private fun captureShare(source: Intent?, restoredId: String?) {
        if (source?.action != Intent.ACTION_SEND && source?.action != Intent.ACTION_SEND_MULTIPLE) return
        val id = restoredId ?: UUID.randomUUID().toString()
        currentShareId = id
        val text = source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: ""
        val uris = linkedSetOf<Uri>()
        if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        source.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        val job = ShareJob(id, uris.size)
        if (shareJobs.putIfAbsent(id, job) != null) return
        publishProgress(job, "queued")
        shareWorker.execute {
            val root = File(filesDir, "share-inbox").apply { mkdirs() }
            val folder = File(root, id)
            try {
                if (job.cancelled) throw ShareCancelled()
                publishProgress(job, "copying")
                val done = getSharedPreferences("shares", MODE_PRIVATE).getStringSet("done", emptySet()) ?: emptySet()
                if (done.contains(id)) { publishProgress(job, "completed"); return@execute }
                if (File(folder, "payload.json").exists()) {
                    publishProgress(job, "ready")
                    return@execute
                }
                if (ShareRecovery.exists(folder)) {
                    recoverShare(folder)
                    publishProgress(job, "ready")
                    return@execute
                }
                require(text.length <= 20000) { "分享文字超过 20000 字，请缩短后重试" }
                require(uris.size <= 100) { "一次最多分享 100 个文件" }
                require(text.isNotBlank() || uris.isNotEmpty()) { "没有可接收的分享内容" }
                folder.mkdirs()
                ShareRecovery.begin(folder, text, uris.size)
                val files = JSONArray()
                uris.forEachIndexed { index, uri ->
                    if (job.cancelled) throw ShareCancelled()
                    require(uri.scheme == "content") { "分享来源未提供可读取的文件" }
                    var name = "shared-file-$index"
                    var size: Long? = null
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                            if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                        }
                    }
                    name = name.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").takeLast(140).ifBlank { "shared-file-$index" }
                    if (name in setOf(".", "..", ".copying")) name = "shared-file-$index"
                    val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
                    ShareRecovery.plan(folder, index, name, mimeType)
                    val fileFolder = File(folder, index.toString()).apply { mkdirs() }
                    val file = File(fileFolder, name)
                    val temp = File(fileFolder, ".copying")
                    if (size != null) require(size <= folder.usableSpace - 16L * 1024 * 1024) { "手机存储空间不足" }
                    publishProgress(job, "copying", name, index + 1, total = size)
                    contentResolver.openInputStream(uri).use { input ->
                        requireNotNull(input) { "无法读取分享文件" }
                        job.input = input
                        temp.outputStream().use { output ->
                            val buffer = ByteArray(256 * 1024)
                            var total = 0L
                            var updatedAt = 0L
                            while (true) {
                                if (job.cancelled) throw ShareCancelled()
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= 100L * 1024 * 1024 * 1024) { "文件超过大小限制" }
                                output.write(buffer, 0, count)
                                val now = SystemClock.elapsedRealtime()
                                if (now - updatedAt >= 100) {
                                    updatedAt = now
                                    publishProgress(job, "copying", name, index + 1, total, size)
                                }
                            }
                            output.fd.sync()
                        }
                    }
                    job.input = null
                    require(temp.renameTo(file)) { "无法保存分享文件" }
                    files.put(JSONObject().put("path", file.absolutePath).put("name", name)
                        .put("mimeType", mimeType))
                }
                synchronized(job) {
                    if (job.cancelled) throw ShareCancelled()
                    job.committing = true
                    writeShare(folder, JSONObject().put("id", id).put("text", text).put("files", files))
                }
                publishProgress(job, "ready")
            } catch (_: ShareCancelled) {
                // Mark the original intent consumed, so activity restoration
                // cannot silently restart an explicitly cancelled import.
                try { acknowledgeShare(id) } catch (_: Exception) { folder.deleteRecursively() }
                publishProgress(job, "cancelled")
            } catch (e: Exception) {
                val cancelled = synchronized(job) {
                    if (job.cancelled) true else { job.committing = true; false }
                }
                if (cancelled) {
                    try { acknowledgeShare(id) } catch (_: Exception) { folder.deleteRecursively() }
                    publishProgress(job, "cancelled")
                } else {
                    folder.mkdirs()
                    try { writeShare(folder, JSONObject().put("id", id).put("error", e.message ?: "分享内容保存失败，请重新分享")) }
                    catch (_: Exception) { activeActivity?.get()?.let { activity -> activity.runOnUiThread { activity.channel?.invokeMethod("shareError", "手机存储不可用，分享未保存") } } }
                    publishProgress(job, "failed")
                }
            } finally {
                job.input = null
                shareJobs.remove(id, job)
                // Pending-share scans skip active jobs. Publish only after the
                // reservation is released, including early recovery returns.
                notifySharesChanged()
            }
        }
    }

    private fun writeShare(folder: File, payload: JSONObject) {
        val temp = File(folder, "payload.pending")
        temp.outputStream().use { output ->
            output.write(payload.toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        require(temp.renameTo(File(folder, "payload.json"))) { "无法保存分享记录" }
    }

    private fun pendingShares(): List<Map<String, Any>> {
        val completed = (getSharedPreferences("shares", MODE_PRIVATE)
            .getStringSet("done", emptySet()) ?: emptySet()).toSet()
        return File(filesDir, "share-inbox").listFiles()?.filter { it.isDirectory }?.sortedBy { it.lastModified() }?.mapNotNull { folder ->
            if (!Regex("^[a-fA-F0-9-]{36}$").matches(folder.name) || shareJobs.containsKey(folder.name)) return@mapNotNull null
            require(folder.canonicalFile.parentFile == File(filesDir, "share-inbox").canonicalFile)
            if (completed.contains(folder.name)) {
                // Retry interrupted cleanup without reviving a cancelled share
                // or importing an already committed message a second time.
                folder.deleteRecursively()
                return@mapNotNull null
            }
            val file = File(folder, "payload.json")
            val value = try {
                if (!file.isFile) recoverShare(folder)
                JSONObject(file.readText())
            } catch (_: Exception) {
                // Keep an actionable record: Dart acknowledges it after showing
                // the error, which also removes this orphan's partial bytes.
                JSONObject().put("id", folder.name).put("error", "上次分享未完成，请重新分享；未完成的临时文件将被清理")
            }
            val result = mutableMapOf<String, Any>("id" to folder.name)
            if (value.has("error")) result["error"] = value.getString("error")
            else {
                result["text"] = value.optString("text")
                if (value.has("recoveredMissing")) result["recoveredMissing"] = value.getInt("recoveredMissing")
                if (value.has("conversationId")) result["conversationId"] = value.getString("conversationId")
                if (value.has("comment")) result["comment"] = value.getString("comment")
                val files = value.optJSONArray("files") ?: JSONArray()
                result["files"] = (0 until files.length()).map { i ->
                    val item = files.getJSONObject(i)
                    mapOf("path" to item.getString("path"), "name" to item.getString("name"), "mimeType" to item.getString("mimeType"))
                }
            }
            result
        } ?: emptyList()
    }

    private fun recoverShare(folder: File) {
        val recovered = ShareRecovery.recover(folder)
        require(recovered.text.isNotBlank() || recovered.files.isNotEmpty()) { "上次分享未完成，请重新分享" }
        val files = JSONArray()
        recovered.files.forEach { file ->
            files.put(JSONObject().put("path", file.path).put("name", file.name).put("mimeType", file.mimeType))
        }
        val payload = JSONObject().put("id", folder.name).put("text", recovered.text).put("files", files)
        if (recovered.missing > 0) payload.put("recoveredMissing", recovered.missing)
        writeShare(folder, payload)
    }

    private fun acknowledgeShare(id: String) {
        require(Regex("^[a-fA-F0-9-]{36}$").matches(id)) { "Invalid share ID" }
        val root = File(filesDir, "share-inbox").canonicalFile
        val folder = File(root, id).canonicalFile
        require(folder.parentFile == root) { "Invalid share path" }
        val preferences = getSharedPreferences("shares", MODE_PRIVATE)
        synchronized(shareStateLock) {
            val done = (preferences.getStringSet("done", emptySet()) ?: emptySet()).toMutableSet()
            done.add(id)
            require(preferences.edit().putStringSet("done", done).commit()) { "无法保存分享状态" }
        }
        if (folder.isDirectory) folder.deleteRecursively()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        collationChannel = MethodChannel(messenger, "lanflow/collation",
            StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
        collationChannel!!.setMethodCallHandler { call, result ->
            if (call.method != "titleKeys") {
                result.notImplemented()
            } else {
                try {
                    val values = call.arguments as? List<*>
                    require(values != null && values.size <= 512) { "Invalid title batch" }
                    val collator = Collator.getInstance(Locale.SIMPLIFIED_CHINESE).apply {
                        strength = Collator.PRIMARY
                    }
                    result.success(values.map { value ->
                        require(value is String && value.length <= 512) { "Invalid title" }
                        collator.getCollationKey(value).toByteArray()
                    })
                } catch (error: Exception) {
                    result.error("COLLATION", "Cannot prepare title sorting", null)
                }
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanflow/platform")
        channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLanguage" -> {
                        ReceiverService.updateState(this, language = if (call.arguments == "en") "en" else "zh")
                        result.success(null)
                    }
                    "setSyncPaused" -> {
                        ReceiverService.updateState(this, paused = call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    "openUrl" -> {
                        try {
                            val uri = Uri.parse(call.arguments as String)
                            require(uri.scheme == "http" || uri.scheme == "https")
                            startActivity(Intent(Intent.ACTION_VIEW, uri))
                            result.success(null)
                        } catch (e: Exception) { result.error("URL", "未找到可以打开此链接的应用", null) }
                    }
                    "showInFolder" -> {
                        val path = call.arguments as? String
                        exportWorker.execute {
                            try {
                                val source = File(requireNotNull(path)).canonicalFile
                                val storageRoots = listOf(filesDir.parentFile!!) + getExternalFilesDirs(null).filterNotNull()
                                require(source.isFile && storageRoots.any { root ->
                                    source.path.startsWith(root.canonicalPath + File.separator)
                                })
                                require(Build.VERSION.SDK_INT >= 29) { "此系统版本请使用另存为选择文件夹" }
                                val values = ContentValues().apply {
                                    put(MediaStore.Downloads.DISPLAY_NAME, source.name)
                                    put(MediaStore.Downloads.MIME_TYPE, URLConnection.guessContentTypeFromName(source.name) ?: "application/octet-stream")
                                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/LanFlow")
                                    put(MediaStore.Downloads.IS_PENDING, 1)
                                }
                                val uri = requireNotNull(contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values))
                                try {
                                    contentResolver.openOutputStream(uri).use { output -> source.inputStream().use { it.copyTo(requireNotNull(output), 256 * 1024) } }
                                    contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                                } catch (e: Exception) { contentResolver.delete(uri, null, null); throw e }
                                runOnUiThread {
                                    try {
                                        val folder = Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADownload%2FLanFlow")
                                        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(folder, "vnd.android.document/directory").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                        result.success(null)
                                    } catch (_: Exception) { result.error("FOLDER", "已保存到下载/LanFlow，系统文件管理器不支持直接定位", null) }
                                }
                            } catch (e: Exception) { runOnUiThread { result.error("FOLDER", e.message, null) } }
                        }
                    }
                    "getPendingShares" -> {
                        controlWorker.execute {
                            try { val pending = pendingShares(); runOnUiThread { result.success(pending) } }
                            catch (e: Exception) { runOnUiThread { result.error("SHARE", e.message, null) } }
                        }
                    }
                    "getNetworkAvailable" -> result.success(networkMonitor.snapshot()["available"])
                    "getNetworkState" -> result.success(networkMonitor.snapshot())
                    "requestDiscoveryWindow" -> {
                        ReceiverService.requestDiscoveryWindow(this, call.argument<Number>("duration")?.toLong() ?: 5000L)
                        result.success(null)
                    }
                    "returnToShareSource" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "setForeground" -> {
                        if (call.arguments == true) ReceiverService.enable(this)
                        result.success(null)
                    }
                    "saveShareTarget" -> {
                        val id = call.argument<String>("id") ?: ""
                        val target = call.argument<String>("conversationId") ?: ""
                        val comment = call.argument<String>("comment") ?: ""
                        controlWorker.execute {
                            try {
                                require(Regex("^[a-fA-F0-9-]{36}$").matches(id))
                                require(Regex("^[A-Za-z0-9_-]{16,64}$").matches(target))
                                require(comment.length <= 20000)
                                val root = File(filesDir, "share-inbox").canonicalFile
                                val folder = File(root, id).canonicalFile
                                require(folder.parentFile == root)
                                val value = JSONObject(File(folder, "payload.json").readText())
                                if (value.has("conversationId")) {
                                    require(value.getString("conversationId") == target && value.optString("comment") == comment)
                                }
                                writeShare(folder, value.put("conversationId", target).put("comment", comment))
                                runOnUiThread { result.success(null) }
                            } catch (e: Exception) { runOnUiThread { result.error("SHARE", e.message, null) } }
                        }
                    }
                    "getShareProgress" -> result.success(shareJobs.values.filter { !it.cancelled }.map { it.progress })
                    "cancelShare" -> {
                        val job = (call.arguments as? String)?.let { shareJobs[it] }
                        val accepted = if (job == null) false else synchronized(job) {
                            if (job.committing || job.progress["phase"] !in setOf("queued", "copying")) false
                            else { job.cancelled = true; true }
                        }
                        if (accepted && job != null) {
                            publishProgress(job, "cancelled")
                            controlWorker.execute { try { job.input?.close() } catch (_: Exception) {} }
                        }
                        result.success(accepted)
                    }
                    "ackShare" -> {
                        val id = call.arguments as? String ?: ""
                        controlWorker.execute {
                            try { acknowledgeShare(id); runOnUiThread { result.success(null) } }
                            catch (e: Exception) { runOnUiThread { result.error("SHARE", e.message, null) } }
                        }
                    }
                    "startReceiver" -> {
                        try {
                            ReceiverService.enable(this)
                            result.success(null)
                        } catch (e: Exception) { result.error("SERVICE", e.message, null) }
                    }
                    "stopReceiver" -> {
                        ReceiverService.stop(this)
                        result.success(null)
                    }
                    "setTransferring" -> {
                        try {
                            ReceiverService.updateState(this, active = call.arguments as? Boolean ?: false)
                            result.success(null)
                        } catch (e: Exception) { result.error("SERVICE", e.message, null) }
                    }
                    "exportFile" -> {
                        if (exportResult != null) {
                            result.error("BUSY", "请先完成当前保存操作", null)
                        } else {
                            val path = call.argument<String>("path")
                            val name = call.argument<String>("name") ?: "file"
                            val source = path?.let { File(it) }
                            if (source == null || !source.isFile) {
                                result.error("MISSING", "文件不存在", null)
                            } else {
                                exportResult = result
                                exportSource = source
                                try {
                                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE)
                                        type = URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
                                        putExtra(Intent.EXTRA_TITLE, name)
                                    }, 91)
                                } catch (e: Exception) {
                                    exportResult = null
                                    exportSource = null
                                    result.error("EXPORT", e.message, null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 91) return
        val callback = exportResult ?: return
        val source = exportSource
        exportResult = null
        exportSource = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) {
            callback.success(false)
            return
        }
        exportWorker.execute {
            try {
                contentResolver.openOutputStream(uri, "w").use { output ->
                    requireNotNull(output) { "无法写入此位置" }
                    source.inputStream().use { input -> input.copyTo(output, 256 * 1024) }
                }
                runOnUiThread { callback.success(true) }
            } catch (e: Exception) {
                runOnUiThread { callback.error("EXPORT", e.message, null) }
            }
        }
    }

    override fun onDestroy() {
        networkMonitor.close()
        if (activeActivity?.get() === this) activeActivity = null
        collationChannel?.setMethodCallHandler(null)
        collationChannel = null
        channel = null
        if (isFinishing) ReceiverService.stop(this)
        super.onDestroy()
    }
}
