package local.multisync

import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Base64

object TicketRules {
    fun host(ticket: String): String {
        val value = ticket.trim()
        require(value.startsWith("msync1:") && value.length <= 16384) { "不是有效的 MultiSync 接收码" }
        val data = JSONObject(String(Base64.getUrlDecoder().decode(value.removePrefix("msync1:")), Charsets.UTF_8))
        require(data.getInt("version") == 1 && data.getInt("port") in 1..65535) { "不支持的接收码版本或端口" }
        val host = data.getString("host")
        require(isPrivate(host)) { "接收码必须指向局域网地址" }
        require(data.getString("token").matches(Regex("[a-fA-F0-9]{64}"))) { "接收密钥无效" }
        require(Base64.getUrlDecoder().decode(data.getString("certificate")).isNotEmpty()) { "接收证书无效" }
        return host
    }
    fun isPrivate(host: String): Boolean {
        val raw = host.split('.')
        if (raw.size != 4 || raw.any { it.isEmpty() || it.any { c -> c !in '0'..'9' } }) return false
        val p = raw.map { it.toIntOrNull() ?: return false }
        if (p.any { it !in 0..255 }) return false
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) ||
            (p[0] == 172 && p[1] in 16..31) || (p[0] == 169 && p[1] == 254)
    }
    fun select(values: List<String>): String {
        val valid = values.map(String::trim).filter { runCatching { host(it) }.isSuccess }.distinct()
        require(valid.isNotEmpty()) { "图片中没有有效的 MultiSync 接收码" }
        require(valid.size == 1) { "图片中有多个不同接收码，请只保留要连接的设备" }
        return valid.single()
    }
}

fun localAddresses(): List<String> = runCatching {
    NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
        .flatMap { it.inetAddresses.toList() }.filterIsInstance<Inet4Address>()
        .mapNotNull { it.hostAddress }.filter { TicketRules.isPrivate(it) && !it.startsWith("127.") }
        .distinct().sorted()
}.getOrDefault(emptyList())

object SafeNames {
    fun file(value: String): String {
        var result = value.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").trim().trimEnd('.')
        if (result.isBlank()) result = "file"
        val stem = result.substringBefore('.').uppercase()
        if (stem in setOf("CON", "PRN", "AUX", "NUL") || stem.matches(Regex("(COM|LPT)[1-9¹²³]")) || result == ".multisync") result = "file_$result"
        while (result.toByteArray(Charsets.UTF_8).size > 220) result = result.substring(0, result.offsetByCodePoints(result.length, -1))
        return result.trimEnd('.', ' ')
    }
}

data class SendTask(val id: String, val path: String, val name: String, val size: Long,
                    val offset: Long = 0, val phase: String = "queued", val message: String = "") {
    fun json() = JSONObject().put("id", id).put("path", path).put("name", name).put("size", size)
        .put("offset", offset).put("phase", phase).put("message", message)
    companion object {
        fun restored(o: JSONObject) = SendTask(o.getString("id"), o.getString("path"), o.getString("name"), o.getLong("size"),
            o.optLong("offset"), if (o.getString("phase") == "completed") "completed" else "paused", o.optString("message"))
    }
}
data class ReceivedTask(val id: String, val name: String, val size: Long, val offset: Long, val state: String, val finalName: String?) {
    companion object {
        fun from(o: JSONObject) = ReceivedTask(o.getString("id"), o.getString("name"), o.getLong("size"),
            o.getLong("offset"), o.getString("state"), if (o.isNull("final_name")) null else o.getString("final_name"))
    }
}
fun phaseLabel(phase: String): String = when (phase) {
    "queued" -> "等待发送"
    "hashing" -> "正在检查原文件"
    "waiting" -> "等待对方确认接收"
    "progress" -> "正在发送"
    "verifying", "committing" -> "正在校验并保存"
    "completed" -> "已完成 · 校验一致"
    "paused", "stopped" -> "已暂停，可继续"
    "failed", "error" -> "未完成，可重试"
    "pending" -> "等待你确认"
    "receiving" -> "已接受 · 等待或接收数据"
    "cancelled" -> "已拒绝"
    else -> phase
}

data class UiState(
    val engineAvailable: Boolean = NativeBridge.available,
    val section: Int = 0,
    val addresses: List<String> = emptyList(),
    val address: String = "",
    val receiveStarting: Boolean = false,
    val receiveRunning: Boolean = false,
    val receiveTicket: String = "",
    val destinationTicket: String = "",
    val destinationHost: String = "",
    val importing: Boolean = false,
    val activeSend: String? = null,
    val outgoing: List<SendTask> = emptyList(),
    val incoming: List<ReceivedTask> = emptyList(),
    val notice: String = "",
    val storageHealthy: Boolean = true
)
