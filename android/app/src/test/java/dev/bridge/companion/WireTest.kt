package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

class WireTest {
    @Test fun handoffMetadataKeepsUsefulTitleWithoutCredentials() {
        assertEquals("Example article", handoffTitle("Example article"))
        assertEquals("", handoffTitle("password=example"))
        assertEquals("Helloworld", handoffTitle("Hello\nworld"))
        assertEquals(160, handoffTitle("a".repeat(200)).length)
        assertFalse(validLink("https://user:password@example.com"))
        assertTrue(validLink("https://example.com/article#section"))
    }

    @Test fun receiverProgressValidationAndSmoothing() {
        val rate = TransferRateEstimator(1000, 0)
        assertTrue(rate.record(100, 1000)); assertEquals(100.0, rate.rate, 0.01)
        assertFalse(rate.record(99, 2000)); assertFalse(rate.record(1001, 2000)); assertFalse(rate.record(200, 1000))
        assertTrue(rate.record(300, 2000)); assertEquals(125.0, rate.rate, 0.01)
    }
    @Test fun etaExcludesUnmeasuredAndCompletedTransfers() {
        assertEquals("~5s left", transferEta(1000, 0.5f, 100.0))
        assertNull(transferEta(1000, 1f, 100.0)); assertNull(transferEta(1000, 0f, 0.0)); assertNull(transferEta(1000, Float.NaN, 100.0))
    }
    @Test fun binaryFrameMixesWithControlsAndPreservesAllBytes() {
        val id = "00112233-4455-6677-8899-aabbccddeeff"
        val bytes = byteArrayOf(0, 10, -1)
        val frame = encodeBinaryChunk(id, 2, bytes)
        assertEquals(52, frame.size); assertArrayEquals(byteArrayOf(0, 0, 0, 0, 47), frame.copyOfRange(0, 5))
        val input = ByteArrayInputStream(Message("ping").encode() + frame + Message("pong").encode())
        assertEquals("ping", Message.read(input)?.type)
        val chunk = Message.read(input)!!
        assertEquals("_binaryChunk", chunk.type); assertEquals(id, chunk.payload.getString("transferID"))
        assertEquals(2L, chunk.payload.getLong("sequence")); assertArrayEquals(bytes, chunk.payload.opt("data") as ByteArray)
        assertEquals("pong", Message.read(input)?.type); assertNull(Message.read(input))
    }
    @Test(expected = IllegalArgumentException::class) fun oversizedBinaryFrameRejectedBeforeAllocation() {
        Message.read(ByteArrayInputStream(byteArrayOf(0, 127, -1, -1, -1)))
    }
    @Test(expected = IllegalArgumentException::class) fun truncatedBinaryRejected() {
        Message.read(ByteArrayInputStream(encodeBinaryChunk("00112233-4455-6677-8899-aabbccddeeff", 0, byteArrayOf(1)).dropLast(1).toByteArray()))
    }
    @Test fun maxBinaryChunkAndShortReadsWork() {
        val frame = encodeBinaryChunk("00112233-4455-6677-8899-aabbccddeeff", 0, ByteArray(BINARY_CHUNK_SIZE) { (it % 256).toByte() })
        val input = object : java.io.FilterInputStream(ByteArrayInputStream(frame)) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(len, 7))
        }
        assertEquals(BINARY_CHUNK_SIZE, (Message.read(input)!!.payload.opt("data") as ByteArray).size)
    }
    @Test(expected = IllegalArgumentException::class) fun jsonCannotForgeBinaryChunk() {
        Message.read(ByteArrayInputStream(Message("_binaryChunk").encode()))
    }
    @Test fun autoReceiveBoundaryRequiresConsentAtOneGB() {
        assertTrue(autoReceiveFile(0)); assertTrue(autoReceiveFile(999_999_999))
        assertFalse(autoReceiveFile(1_000_000_000)); assertFalse(autoReceiveFile(MAX_FILE_BYTES)); assertFalse(autoReceiveFile(-1))
    }
    @Test fun unicodeSurvivesWireRoundTrip() {
        val value = "Hello Pixel 👋\nMac → Android"
        val message = Message("clipboard", payload("text" to value))
        val decoded = Message.read(ByteArrayInputStream(message.encode()))!!
        assertEquals(message.id, decoded.id); assertEquals(value, decoded.payload.getString("text"))
    }
    @Test fun consecutiveFramesStaySeparate() {
        val input = ByteArrayInputStream(Message("ping").encode() + Message("pong").encode())
        assertEquals("ping", Message.read(input)?.type); assertEquals("pong", Message.read(input)?.type); assertNull(Message.read(input))
    }
    @Test(expected = IllegalArgumentException::class) fun rejectOversizedFrames() {
        Message.read(ByteArrayInputStream(ByteArray(Message.MAX_FRAME + 1) { 65 }))
    }
    @Test(expected = IllegalArgumentException::class) fun rejectTruncatedFrames() { Message.read(ByteArrayInputStream("{\"v\":1}".toByteArray())) }
    @Test fun rejectUnsafeTransferNames() {
        listOf("../secret", "..", "a/b", "a\\b", "a\u0000b").forEach { assertFalse(validFileName(it)) }
        assertTrue(validFileName("My photo 🖼.png"))
    }
    @Test fun linksMustBeWebLinks() { assertFalse(validLink("file:///etc/passwd")); assertFalse(validLink("javascript:alert(1)")); assertTrue(validLink("https://example.com/a")) }
    @Test fun digestMatchesKnownVector() { assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256("abc".toByteArray())) }
    @Test fun pairingParsesPinnedIdentityAndGeneratesDistinctCredentials() {
        val token = java.util.Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
        val url = "bridge://pair?host=192.168.1.20&port=51234&fingerprint=${"a".repeat(64)}&token=${java.net.URLEncoder.encode(token, "UTF-8")}&name=My%20Mac&service=Bridge-aaaaaaaa"
        val first = Pairing.fromURL(url); val second = Pairing.fromURL(url)
        assertEquals("My Mac", first.name); assertEquals(51234, first.port)
        assertEquals(32, java.util.Base64.getDecoder().decode(first.credential).size)
        assertNotEquals(first.credential, second.credential); assertNotEquals(first.deviceID, second.deviceID)
    }
    @Test(expected = IllegalArgumentException::class) fun pairingRejectsOtherSchemes() { Pairing.fromURL("https://example.com/pair") }
    @Test(expected = IllegalArgumentException::class) fun pairingRejectsInvalidPin() { Pairing.fromURL("bridge://pair?host=192.168.1.20&port=51234&fingerprint=bad&token=bad") }
    @Test fun pairingPreservesLiteralPlusInMacQRCode() {
        val token = java.util.Base64.getEncoder().encodeToString(ByteArray(32) { 0xfb.toByte() })
        assertTrue(token.contains('+'))
        val pairing = Pairing.fromURL("bridge://pair?host=192.168.1.20&port=51234&fingerprint=${"a".repeat(64)}&token=$token&name=Mac")
        assertEquals(token, pairing.token)
    }
}
