package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test

class ClipboardHistoryTest {
    @Test fun secretsNeverEnterHistoryEvenAfterUserApprovedSending() {
        val history = ClipboardHistory()
        listOf("123456", "password=example", "ghp_" + "a".repeat(24), "-----BEGIN PRIVATE KEY-----").forEach { history.record(it, "Phone", 0) }
        history.record("Normal message", "Mac", 0)
        assertEquals(listOf("Normal message"), history.entries(1).map { it.text })
    }
    @Test fun pinSurvivesExpiryButHardCapStillApplies() {
        val history = ClipboardHistory()
        history.record("Pinned message", "Mac", 0)
        history.togglePin(history.entries(0).first().id)
        history.record("Unpinned message", "Mac", 0)
        assertEquals("Pinned message", history.entries(86_400_000).single().text)
        repeat(101) { history.record("Message $it", "Mac", 86_400_001) }
        assertEquals(100, history.entries(86_400_002).size)
        assertFalse(history.entries(86_400_002).any { it.text == "Pinned message" })
    }
    @Test fun duplicateRefreshPreservesPinAndSourceIdentity() {
        val history = ClipboardHistory()
        history.record("Hello", "Phone", 0)
        history.togglePin(history.entries(0).first().id)
        history.record("Hello", "Phone", 1)
        history.record("Hello", "Mac", 2)
        assertEquals(2, history.entries(2).size)
        assertTrue(history.entries(2).first { it.source == "Phone" }.pinned)
    }
    @Test fun deleteClearAndMemoryBounds() {
        val history = ClipboardHistory()
        history.record("a".repeat(32769), "Phone", 0)
        history.record(" ", "Phone", 0)
        assertTrue(history.entries(0).isEmpty())
        history.record("Accepted text", "Mac", 0)
        history.delete(history.entries(0).single().id)
        assertTrue(history.entries(0).isEmpty())
        history.record("Another", "Mac", 0); history.clear()
        assertTrue(history.entries(0).isEmpty())
        assertTrue(ClipboardHistory().entries(0).isEmpty())
    }
}
