package local.multisync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class ContractTests {
    private fun ticket(host: String = "192.168.1.8") = "msync1:" + Base64.getUrlEncoder().withoutPadding().encodeToString(
        JSONObject().put("version", 1).put("host", host).put("port", 53318).put("token", "a".repeat(64))
            .put("certificate", "AQID").toString().toByteArray())
    @Test fun localInvitationAndCopyTextRoundTrip() {
        val value = ticket()
        assertEquals("192.168.1.8", TicketRules.host("  $value\n"))
        assertEquals(value, TicketRules.select(listOf(value, value, "https://example.com")))
    }
    @Test fun publicAddressAndAmbiguousImagesAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { TicketRules.host(ticket("8.8.8.8")) }
        assertThrows(IllegalArgumentException::class.java) { TicketRules.select(listOf(ticket(), ticket("10.0.0.9"))) }
        assertFalse(TicketRules.isPrivate("192.168.1.999"))
        assertFalse(TicketRules.isPrivate("10.0.0.-1"))
    }
    @Test fun restoreNeverClaimsAnInterruptedTransferCompleted() {
        val task = SendTask("id", "/private/file", "file", 1024, 512, "progress")
        assertEquals("paused", SendTask.restored(task.json()).phase)
        assertEquals(512L, SendTask.restored(task.json()).offset)
        assertEquals("completed", SendTask.restored(task.copy(phase = "completed").json()).phase)
    }
    @Test fun stagedNamesCannotEscapePrivateDirectory() {
        assertEquals(".._outside", SafeNames.file("../outside"))
        assertEquals("file_CON.txt", SafeNames.file("CON.txt"))
        assertEquals("file_.multisync", SafeNames.file(".multisync"))
        assertEquals("照片.jpg", SafeNames.file("照片.jpg"))
        assertFalse(SafeNames.file("a\nb").contains('\n'))
        assertTrue(SafeNames.file("照片".repeat(200)).toByteArray().size <= 220)
    }
}
