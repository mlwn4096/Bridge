package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.util.Base64

class PairingTest {
    private val token = Base64.getEncoder().encodeToString(ByteArray(32) { -5 })
    private val url = "bridge://pair?host=192.168.1.2&port=38473&fingerprint=${"a".repeat(64)}&token=$token&name=My%20Mac&service=Bridge"

    @Test fun literalPlusInTokenSurvivesUriParsing() {
        val peer = Pairing.fromURL(url)
        assertEquals(token, peer.token)
        assertEquals("My Mac", peer.name)
        assertEquals(32, Base64.getDecoder().decode(peer.credential).size)
    }
    @Test fun rejectsAmbiguousAndUnexpectedPairingUris() {
        listOf("$url&host=other", url.replace("bridge://pair?", "bridge://user@pair?"),
            "$url#fragment", url.replace("bridge://pair?", "bridge://pair/path?"),
            url.replace("port=38473", "port=0")).forEach { invalid ->
            assertTrue(invalid, runCatching { Pairing.fromURL(invalid) }.isFailure)
        }
    }
    @Test fun storedCredentialsAreValidatedAndEnrollmentTokenNeverRestored() {
        val stored = Pairing.fromURL(url).copy(token = "").json()
        assertEquals("My Mac", Pairing.fromJSON(stored).name)
        assertTrue(runCatching { Pairing.fromJSON(JSONObject(stored.toString()).put("credential", "bad")) }.isFailure)
        assertTrue(runCatching { Pairing.fromJSON(JSONObject(stored.toString()).put("token", token)) }.isFailure)
    }
    @Test fun historyRetainsLiveTransfersBeyondCompletedHistoryCap() {
        val active = Transfer("active", "Large file", 100, true, "Receiving")
        val completed = (1..60).map { Transfer("done$it", "File", 1, true, "Complete") }
        val history = retainedTransfers(Transfer("new", "File", 1, true, "Complete"), completed + active)
        assertEquals(51, history.size)
        assertTrue(history.any { it.id == "active" })
        assertEquals(50, history.count { it.status == "Complete" })
    }
}
