package local.multisync

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID

/** Uses the packaged native library, real TLS sockets and real SQLite/filesystem state. */
@RunWith(AndroidJUnit4::class)
class BridgeSmokeTest {
    private var phase = "initialization"
    private fun phase(value: String) {
        phase = value
        Log.i("MultiSyncSmoke", value)
    }
    private fun call(vararg pairs: Pair<String, Any>): JSONObject {
        val request = JSONObject(); pairs.forEach { (key, value) -> request.put(key, value) }
        val response = JSONObject(NativeBridge.call(request.toString()))
        assertTrue("$phase / ${request.optString("op")}: ${response.optString("error", "native bridge request failed")}", response.optBoolean("ok"))
        return response
    }
    private fun until(timeoutMs: Long, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            Thread.sleep(40)
        }
        fail("$phase: native transfer did not reach its expected state within $timeoutMs ms")
    }
    @Test(timeout = 60000)
    fun packagedJNITransfersAndResumesWithoutDeletingSource() {
        assertTrue("APK must contain the real Rust JNI library", NativeBridge.available)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        phase("Android permission and loopback socket precheck")
        assertEquals("Target application must have INTERNET permission", PackageManager.PERMISSION_GRANTED,
            context.checkSelfPermission(Manifest.permission.INTERNET))
        Log.i("MultiSyncSmoke", "package=${context.packageName}; API=${Build.VERSION.SDK_INT}; ABI=${Build.SUPPORTED_ABIS.joinToString()}; uid=${android.os.Process.myUid()}")
        val loopback = InetAddress.getByName("127.0.0.1")
        ServerSocket(0, 1, loopback).use { server ->
            server.soTimeout = 2000
            Socket().use { client ->
                client.connect(InetSocketAddress(loopback, server.localPort), 2000)
                server.accept().use { peer -> assertTrue("Loopback peer must be connected", peer.isConnected) }
            }
        }
        phase("Application private storage precheck")
        val root = File(context.cacheDir, "bridge-test-${UUID.randomUUID()}")
        assertTrue("Cannot create test directory in target app cache", root.mkdirs())
        val inbox = File(root, "inbox").apply { assertTrue("Cannot create receiver directory", mkdirs()) }
        val original = File(root, "source.bin")
        val data = ByteArray(1024 * 1024 + 91) { index -> (index * 31 % 251).toByte() }
        original.writeBytes(data)
        assertArrayEquals("Target app storage read/write failed", data, original.readBytes())
        // The real native commit must choose a new final name, never replace an existing file.
        val existing = File(inbox, original.name)
        val existingData = "existing receiver file must survive".toByteArray(Charsets.UTF_8)
        existing.writeBytes(existingData)
        val journal = File(root, "outgoing/job.json")
        val handles = mutableListOf<String>()
        try {
            phase("Receiver startup: native store, identity, TLS and bind")
            val receiver = call("op" to "start_receive", "inbox" to inbox.absolutePath, "host" to "127.0.0.1", "port" to 0).getString("handle")
            handles += receiver
            var ticket = ""
            until(10000) {
                val events = call("op" to "poll", "handle" to receiver).getJSONArray("events")
                for (index in 0 until events.length()) {
                    val event = events.getJSONObject(index)
                    if (event.getString("event") == "error") fail("$phase: ${event.optString("message")}")
                    if (event.getString("event") == "ready") ticket = event.getString("ticket")
                }
                ticket.isNotEmpty()
            }
            phase("Initial send: native journal, TLS, approval and file commit")
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
                    Log.i("MultiSyncSmoke", "sender event=${event.optString("event")}; offset=${event.optLong("offset")}")
                    if (event.getString("event") == "error") fail("$phase: ${event.optString("message")}")
                    if (event.getString("event") == "completed") delivered = true
                }
                delivered
            }
            phase("Verify content, source retention and same-name collision preservation")
            val first = call("op" to "jobs", "inbox" to inbox.absolutePath).getJSONArray("jobs")
            assertEquals(1, first.length())
            val received = first.getJSONObject(0)
            assertEquals("completed", received.getString("state"))
            assertNotEquals("Receiver must not replace a same-name file", original.name, received.getString("final_name"))
            assertArrayEquals(data, File(inbox, received.getString("final_name")).readBytes())
            assertArrayEquals(data, original.readBytes())
            assertArrayEquals("Existing receiver file was overwritten", existingData, existing.readBytes())

            phase("Resume completed journal: no duplicate received copy")
            val resumed = call("op" to "send", "journal" to journal.absolutePath).getString("handle")
            handles += resumed
            until(10000) {
                val events = call("op" to "poll", "handle" to resumed).getJSONArray("events")
                var complete = false
                for (index in 0 until events.length()) {
                    val event = events.getJSONObject(index)
                    if (event.getString("event") == "error") fail("$phase: ${event.optString("message")}")
                    if (event.getString("event") == "completed") complete = true
                }
                complete
            }
            assertEquals(2, inbox.listFiles()!!.count { it.isFile })
            assertArrayEquals(data, original.readBytes())
            assertArrayEquals(existingData, existing.readBytes())
            phase("Receiver graceful shutdown")
            call("op" to "stop", "handle" to receiver)
            until(6000) { call("op" to "poll", "handle" to receiver).optBoolean("finished") }
        } finally {
            handles.asReversed().forEach { runCatching { call("op" to "release", "handle" to it) } }
            root.deleteRecursively()
        }
    }
}
