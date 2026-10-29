package local.multisync

import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Uses the packaged native library, real TLS sockets and real SQLite/filesystem state. */
@RunWith(AndroidJUnit4::class)
class BridgeSmokeTest {
    private fun call(vararg pairs: Pair<String, Any>): JSONObject {
        val request = JSONObject(); pairs.forEach { (key, value) -> request.put(key, value) }
        val response = JSONObject(NativeBridge.call(request.toString()))
        assertTrue(response.optString("error", "native bridge request failed"), response.optBoolean("ok"))
        return response
    }
    private fun until(timeoutMs: Long, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            Thread.sleep(40)
        }
        fail("native transfer did not reach its expected state before timeout")
    }
    @Test(timeout = 60000)
    fun packagedJNITransfersAndResumesWithoutDeletingSource() {
        assertTrue("APK must contain the real Rust JNI library", NativeBridge.available)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "bridge-test-${UUID.randomUUID()}").apply { mkdirs() }
        val inbox = File(root, "inbox")
        val original = File(root, "source.bin")
        val data = ByteArray(1024 * 1024 + 91) { index -> (index * 31 % 251).toByte() }
        original.writeBytes(data)
        val journal = File(root, "outgoing/job.json")
        val handles = mutableListOf<String>()
        try {
            val receiver = call("op" to "start_receive", "inbox" to inbox.absolutePath, "host" to "127.0.0.1", "port" to 0).getString("handle")
            handles += receiver
            var ticket = ""
            until(10000) {
                val events = call("op" to "poll", "handle" to receiver).getJSONArray("events")
                for (index in 0 until events.length()) {
                    val event = events.getJSONObject(index)
                    if (event.getString("event") == "error") fail(event.optString("message"))
                    if (event.getString("event") == "ready") ticket = event.getString("ticket")
                }
                ticket.isNotEmpty()
            }
            val sender = call("op" to "send", "source" to original.absolutePath, "journal" to journal.absolutePath, "ticket" to ticket).getString("handle")
            handles += sender
            var delivered = false
            until(20000) {
                val jobs = call("op" to "jobs", "inbox" to inbox.absolutePath).getJSONArray("jobs")
                for (index in 0 until jobs.length()) {
                    val job = jobs.getJSONObject(index)
                    if (job.getString("state") == "pending") call("op" to "approve", "inbox" to inbox.absolutePath, "id" to job.getString("id"))
                }
                val events = call("op" to "poll", "handle" to sender).getJSONArray("events")
                for (index in 0 until events.length()) {
                    val event = events.getJSONObject(index)
                    if (event.getString("event") == "error") fail(event.optString("message"))
                    if (event.getString("event") == "completed") delivered = true
                }
                delivered
            }
            val first = call("op" to "jobs", "inbox" to inbox.absolutePath).getJSONArray("jobs")
            assertEquals(1, first.length())
            val received = first.getJSONObject(0)
            assertEquals("completed", received.getString("state"))
            assertArrayEquals(data, File(inbox, received.getString("final_name")).readBytes())
            assertArrayEquals(data, original.readBytes())

            val resumed = call("op" to "send", "journal" to journal.absolutePath).getString("handle")
            handles += resumed
            until(10000) {
                val events = call("op" to "poll", "handle" to resumed).getJSONArray("events")
                var complete = false
                for (index in 0 until events.length()) {
                    val event = events.getJSONObject(index)
                    if (event.getString("event") == "error") fail(event.optString("message"))
                    if (event.getString("event") == "completed") complete = true
                }
                complete
            }
            assertEquals(1, inbox.listFiles()!!.count { it.isFile })
            assertArrayEquals(data, original.readBytes())
            call("op" to "stop", "handle" to receiver)
            until(6000) { call("op" to "poll", "handle" to receiver).optBoolean("finished") }
        } finally {
            handles.asReversed().forEach { runCatching { call("op" to "release", "handle" to it) } }
            root.deleteRecursively()
        }
    }
}
