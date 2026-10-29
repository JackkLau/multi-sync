package local.multisync

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import android.util.AtomicFile
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class TransferModel(application: Application) : AndroidViewModel(application), DefaultLifecycleObserver {
    private val app = application
    val inbox = File(app.filesDir, "inbox").apply { mkdirs() }
    private val outgoingRoot = File(app.filesDir, "outgoing").apply { mkdirs() }
    private val queueFile = AtomicFile(File(app.filesDir, "queue.json"))
    private val mutable = MutableStateFlow(UiState())
    val state = mutable.asStateFlow()
    private var receiverHandle: String? = null
    private var senderHandle: String? = null
    private var receiverPoll: Job? = null
    private var senderPoll: Job? = null
    private var foreground = true
    private var generation = 0
    private val persistenceMutex = Mutex()
    private var senderStopRequested = false
    private var receiverStopRequested = false

    init {
        ProcessLifecycleOwner.get().lifecycle.addObserver(this)
        refreshAddresses()
        try {
            if (queueFile.baseFile.exists()) {
                val array = JSONArray(queueFile.readFully().toString(Charsets.UTF_8))
                mutable.value = mutable.value.copy(outgoing = (0 until array.length()).map { SendTask.restored(array.getJSONObject(it)) })
            }
        } catch (_: Exception) {
            mutable.value = mutable.value.copy(storageHealthy = false, notice = "无法读取已有任务记录，已停止新建任务以保护历史。请保留应用数据并检查存储空间。")
        }
        if (!NativeBridge.available) notice("传输引擎未打包，请使用完整构建的 APK。")
        else viewModelScope.launch { runCatching { refreshIncoming() }.onFailure { notice(it.message ?: "无法读取接收记录") } }
    }

    override fun onStart(owner: LifecycleOwner) { foreground = true; refreshAddresses() }
    override fun onStop(owner: LifecycleOwner) {
        foreground = false; generation++
        if (receiverHandle != null || senderHandle != null || state.value.receiveStarting || state.value.activeSend != null) {
            stopReceiving(); pauseSend()
            notice("应用已进入后台，收发已暂停。回到应用后可重新开启接收或继续发送；任务会保留。")
        }
    }

    fun section(value: Int) { mutable.value = state.value.copy(section = value) }
    fun notice(value: String) { mutable.value = state.value.copy(notice = value) }
    fun selectAddress(value: String) { if (!state.value.receiveRunning && !state.value.receiveStarting) mutable.value = state.value.copy(address = value) }
    fun refreshAddresses() {
        val addresses = localAddresses()
        mutable.value = state.value.copy(addresses = addresses, address = state.value.address.takeIf { it in addresses } ?: addresses.firstOrNull().orEmpty())
    }

    private suspend fun call(vararg pairs: Pair<String, Any>): JSONObject = withContext(Dispatchers.IO) {
        check(NativeBridge.available) { "传输引擎不可用，请安装完整构建的 APK" }
        val request = JSONObject()
        pairs.forEach { (key, value) -> request.put(key, value) }
        val result = JSONObject(NativeBridge.call(request.toString()))
        check(result.optBoolean("ok")) { result.optString("error", "传输引擎未完成操作") }
        result
    }

    // A cancelled ViewModel must still stop native tasks before dropping their handles.
    private suspend fun stopAndRelease(handle: String) = withContext(NonCancellable) {
        try {
            runCatching { call("op" to "stop", "handle" to handle) }
            withTimeoutOrNull(5000) {
                while (!call("op" to "poll", "handle" to handle).optBoolean("finished")) delay(50)
            }
        } catch (_: Exception) {
            // release also signals stop, including when polling cannot complete.
        } finally {
            runCatching { call("op" to "release", "handle" to handle) }
        }
    }

    fun useInvitation(value: String) {
        if (state.value.importing) return
        viewModelScope.launch {
            runCatching {
                val ticket = value.trim()
                TicketRules.host(ticket)
                val parsed = call("op" to "validate_ticket", "ticket" to ticket)
                mutable.value = state.value.copy(destinationTicket = ticket, destinationHost = parsed.getString("host"),
                    section = 0, notice = "已连接接收码。选择文件并点击发送，对方仍需确认。")
            }.onFailure { notice(it.message ?: "接收码无效，请重新扫描") }
        }
    }

    fun importQRCode(uri: Uri) {
        if (state.value.importing) return
        mutable.value = state.value.copy(importing = true)
        viewModelScope.launch {
            try {
                val ticket = withContext(Dispatchers.IO) { QRImages.read(app, uri) }
                TicketRules.host(ticket)
                val parsed = call("op" to "validate_ticket", "ticket" to ticket)
                mutable.value = state.value.copy(destinationTicket = ticket, destinationHost = parsed.getString("host"),
                    section = 0, notice = "已识别接收码，可以选择文件发送。")
            } catch (e: Exception) { notice(e.message ?: "无法识别二维码图片") }
            finally { mutable.value = state.value.copy(importing = false) }
        }
    }

    fun importFiles(uris: List<Uri>) {
        if (state.value.importing || !state.value.storageHealthy || uris.isEmpty()) return
        mutable.value = state.value.copy(importing = true)
        viewModelScope.launch {
            try {
                for (uri in uris) {
                    val record = withContext(Dispatchers.IO) {
                        val id = UUID.randomUUID().toString()
                        val directory = File(outgoingRoot, id).apply { check(mkdirs()) { "无法创建文件暂存目录" } }
                        var originalName = "file"
                        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                            if (cursor.moveToFirst()) originalName = cursor.getString(0) ?: "file"
                        }
                        val file = File(directory, SafeNames.file(originalName))
                        try {
                            app.contentResolver.openInputStream(uri)?.use { input ->
                                FileOutputStream(file).use { output -> input.copyTo(output); output.fd.sync() }
                            } ?: error("无法读取所选文件，请重新授权")
                            SendTask(id, file.absolutePath, file.name, file.length())
                        } catch (error: Exception) { file.delete(); throw error }
                    }
                    mutable.value = state.value.copy(outgoing = state.value.outgoing + record)
                    persist()
                }
                notice("文件已加入待发送列表。原文件会保留。")
            } catch (error: Exception) { notice(error.message ?: "无法准备文件，请检查权限和空间") }
            finally { mutable.value = state.value.copy(importing = false) }
        }
    }

    private suspend fun persist() = persistenceMutex.withLock {
        val records = state.value.outgoing
        withContext(Dispatchers.IO) {
            val array = JSONArray(); records.forEach { array.put(it.json()) }
            var output: FileOutputStream? = null
            try {
                output = queueFile.startWrite()
                output.write(array.toString().toByteArray(Charsets.UTF_8))
                queueFile.finishWrite(output)
            } catch (e: Exception) { queueFile.failWrite(output); throw e }
        }
    }
    private fun update(id: String, transform: (SendTask) -> SendTask) {
        mutable.value = state.value.copy(outgoing = state.value.outgoing.map { if (it.id == id) transform(it) else it })
    }

    fun startSending(id: String) {
        if (!foreground || state.value.activeSend != null || !state.value.storageHealthy) return
        val record = state.value.outgoing.firstOrNull { it.id == id } ?: return
        if (record.phase == "completed") return
        val journal = File(outgoingRoot, "$id/job.json")
        if (!journal.exists() && state.value.destinationTicket.isBlank()) { notice("请先扫描对方的接收码"); return }
        val ticket = state.value.destinationTicket
        val attempt = generation
        senderStopRequested = false
        mutable.value = state.value.copy(activeSend = id)
        update(id) { it.copy(phase = "hashing", message = "") }
        senderPoll = viewModelScope.launch {
            var handle: String? = null
            try {
                persist()
                val params = mutableListOf("op" to "send", "journal" to journal.absolutePath)
                if (!journal.exists()) { params += "source" to record.path; params += "ticket" to ticket }
                withContext(NonCancellable) {
                    // Ownership is recorded before cancellation can discard a newly created handle.
                    handle = call(*params.toTypedArray()).getString("handle")
                    senderHandle = handle
                }
                val activeHandle = checkNotNull(handle)
                if (attempt != generation || !foreground || senderStopRequested) { call("op" to "stop", "handle" to activeHandle) }
                while (true) {
                    val result = call("op" to "poll", "handle" to activeHandle)
                    val events = result.getJSONArray("events")
                    for (index in 0 until events.length()) {
                        val event = events.getJSONObject(index)
                        val kind = event.getString("event")
                        update(id) { old -> old.copy(phase = when (kind) { "error" -> "failed"; "stopped" -> "paused"; else -> kind },
                            offset = event.optLong("offset", old.offset), size = event.optLong("size", old.size),
                            message = if (kind == "error") event.optString("message", "发送未完成") else old.message) }
                    }
                    if (events.length() > 0) persist()
                    if (result.optBoolean("finished")) break
                    delay(300)
                }
                if (state.value.outgoing.first { it.id == id }.phase !in listOf("completed", "failed", "paused")) update(id) { it.copy(phase = "paused") }
                persist()
            } catch (e: CancellationException) {
                update(id) { if (it.phase == "completed") it else it.copy(phase = "paused", message = "") }
                throw e
            } catch (e: Exception) {
                update(id) { it.copy(phase = "failed", message = e.message ?: "连接中断，可继续") }
            } finally {
                withContext(NonCancellable) {
                    handle?.let { stopAndRelease(it) }
                    senderHandle = null
                    mutable.value = state.value.copy(activeSend = null)
                    runCatching { persist() }.onFailure { mutable.value = state.value.copy(storageHealthy = false) }
                }
            }
        }
    }

    fun pauseSend() {
        senderStopRequested = true
        val handle = senderHandle
        if (handle != null) viewModelScope.launch { runCatching { call("op" to "stop", "handle" to handle) }.onFailure { notice(it.message.orEmpty()) } }
    }

    fun startReceiving() {
        if (!foreground || state.value.receiveStarting || state.value.receiveRunning) return
        val host = state.value.address
        if (host.isBlank()) { refreshAddresses(); notice("没有可用局域网地址，请连接 Wi-Fi 或热点后刷新"); return }
        val attempt = generation
        receiverStopRequested = false
        mutable.value = state.value.copy(receiveStarting = true, receiveTicket = "")
        receiverPoll = viewModelScope.launch {
            var handle: String? = null
            try {
                withContext(NonCancellable) {
                    handle = call("op" to "start_receive", "inbox" to inbox.absolutePath, "host" to host, "port" to 53318).getString("handle")
                    receiverHandle = handle
                }
                val activeHandle = checkNotNull(handle)
                if (attempt != generation || !foreground || receiverStopRequested) call("op" to "stop", "handle" to activeHandle)
                while (true) {
                    val result = call("op" to "poll", "handle" to activeHandle)
                    val events = result.getJSONArray("events")
                    for (index in 0 until events.length()) {
                        val event = events.getJSONObject(index)
                        when (event.getString("event")) {
                            "ready" -> mutable.value = state.value.copy(receiveStarting = false, receiveRunning = true,
                                receiveTicket = event.getString("ticket"), notice = "接收已开启。让发送设备扫描二维码，或直接复制、分享接收码。")
                            "error" -> notice(event.optString("message", "接收服务已停止"))
                        }
                    }
                    refreshIncoming()
                    if (result.optBoolean("finished")) break
                    delay(500)
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { notice(e.message ?: "接收服务未能启动") }
            finally {
                withContext(NonCancellable) {
                    handle?.let { stopAndRelease(it) }
                    receiverHandle = null
                    mutable.value = state.value.copy(receiveStarting = false, receiveRunning = false, receiveTicket = "")
                }
            }
        }
    }

    fun stopReceiving() {
        receiverStopRequested = true
        receiverHandle?.let { handle -> viewModelScope.launch {
            runCatching { call("op" to "stop", "handle" to handle) }.onFailure { notice(it.message.orEmpty()) }
        } }
    }
    private suspend fun refreshIncoming() {
        val jobs = call("op" to "jobs", "inbox" to inbox.absolutePath).getJSONArray("jobs")
        mutable.value = state.value.copy(incoming = (0 until jobs.length()).map { ReceivedTask.from(jobs.getJSONObject(it)) })
    }
    fun decide(id: String, accept: Boolean) { viewModelScope.launch {
        runCatching {
            call("op" to if (accept) "approve" else "reject", "inbox" to inbox.absolutePath, "id" to id)
            refreshIncoming()
        }.onFailure { notice(it.message ?: "接收确认未完成") }
    } }
    fun completedFile(task: ReceivedTask): File? {
        if (task.state != "completed" || task.finalName == null) return null
        val file = File(inbox, task.finalName).canonicalFile
        return file.takeIf { it.parentFile == inbox.canonicalFile && it.isFile }
    }
    fun export(task: ReceivedTask, target: Uri) { viewModelScope.launch {
        runCatching {
            val source = completedFile(task) ?: error("接收文件尚未完成或已被移动")
            withContext(Dispatchers.IO) {
                app.contentResolver.openOutputStream(target, "w")?.use { output -> source.inputStream().use { it.copyTo(output) } }
                    ?: error("无法写入所选位置")
            }
            notice("文件已另存，应用内接收副本仍保留。")
        }.onFailure { notice(it.message ?: "文件导出失败") }
    } }
    override fun onCleared() {
        ProcessLifecycleOwner.get().lifecycle.removeObserver(this)
        foreground = false
        generation++
        receiverStopRequested = true
        senderStopRequested = true
        receiverPoll?.cancel()
        senderPoll?.cancel()
        listOfNotNull(receiverHandle, senderHandle).forEach { handle ->
            // Each task's non-cancellable finalizer drains and releases its own handle.
            runCatching { NativeBridge.call(JSONObject().put("op", "stop").put("handle", handle).toString()) }
        }
        super.onCleared()
    }
}
