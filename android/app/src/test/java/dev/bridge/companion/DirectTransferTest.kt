package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class DirectTransferTest {
    private fun rejects(action: () -> Unit) { try { action(); fail("Expected rejection") } catch (_: IllegalArgumentException) { } }
    @Test fun discoveryHintsAreSessionScopedAndBounded() {
        val session = DirectSession.create()
        val packet = payload("type" to "bridgeDirectV1", "sessionID" to session.id, "port" to 12345).toString().toByteArray()
        assertEquals("192.168.45.2" to 12345, session.endpoint(packet, "192.168.45.2"))
        assertNull(DirectSession.create().endpoint(packet, "192.168.45.2"))
        for (host in listOf("127.0.0.1", "8.8.8.8", "192.168.45.255", "192.168.45.0", "192.168.999.2", "::1")) assertNull(session.endpoint(packet, host))
        assertNull(session.endpoint(ByteArray(1025), "192.168.45.2"))
        assertNull(session.endpoint(payload("type" to "bridgeDirectV1", "sessionID" to session.id, "port" to 65536).toString().toByteArray(), "192.168.45.2"))
        assertFalse(String(packet).contains(session.password))
    }
    @Test fun generatedHotspotCredentialsFitTheSharedContract() {
        repeat(100) {
            val value = DirectSession.create()
            assertEquals(15, value.ssid.length); assertTrue(value.ssid.matches(Regex("Bridge-[0-9a-f]{8}")))
            assertTrue(value.password.matches(Regex("[0-9a-f]{24}")))
        }
    }
    @Test fun probeRejectsWrongSessionOutOfOrderAndIncompleteData() {
        val probe = SpeedProbe(UUID.randomUUID().toString(), SPEED_PROBE_BYTES)
        rejects { probe.append(UUID.randomUUID().toString(), 0, byteArrayOf(1), 1) }
        rejects { probe.append(probe.id, 1, byteArrayOf(1), 1) }
        rejects { probe.append(probe.id, 0, ByteArray(0), 1) }
        rejects { probe.finish() }
        rejects { SpeedProbe(probe.id, SPEED_PROBE_BYTES * 2) }
    }
    @Test fun probeCountsOnlyACompleteOrderedBoundedStream() {
        val probe = SpeedProbe(UUID.randomUUID().toString(), SPEED_PROBE_BYTES)
        val bytes = ByteArray(BINARY_CHUNK_SIZE)
        repeat(128) { probe.append(probe.id, it.toLong(), bytes, (it + 1L) * 10_000_000) }
        assertEquals(SPEED_PROBE_BYTES, probe.received)
        assertEquals(1.27, probe.finish(), 0.00001)
        rejects { probe.append(probe.id, 128, bytes, 2_000_000_000) }
    }
    @Test fun telemetrySeparatesPreparationWaitingStreamingAndFinish() {
        var value = TransferTimings()
        for ((state, time) in listOf("Preparing" to 1000L, "Waiting for computer" to 3000L, "Sending" to 5000L, "Finishing" to 15000L, "Verifying" to 16000L, "Complete" to 17000L)) value = value.transition(state, time)
        assertEquals(16000L, value.total)
        assertEquals(mapOf("preparation" to 2000L, "waiting" to 2000L, "transfer" to 10000L, "finish" to 2000L), value.milliseconds)
        assertEquals(value, value.transition("Complete", 20000L))
        val retry = value.transition("Preparing", 21000L)
        assertNull(retry.total); assertTrue(retry.milliseconds.isEmpty())
    }
}
