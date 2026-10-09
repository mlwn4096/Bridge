package dev.bridge.companion

import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow

/** Process-memory only: never serialized, including pinned entries. */
data class ClipboardHistoryEntry(val id: String = UUID.randomUUID().toString(), val text: String,
    val source: String, val createdAt: Long, val pinned: Boolean = false)

class ClipboardHistory {
    companion object { val session = ClipboardHistory() }
    private val items = mutableListOf<ClipboardHistoryEntry>()
    val revision = MutableStateFlow(0L)
    @Synchronized fun entries(now: Long = System.currentTimeMillis()): List<ClipboardHistoryEntry> {
        val count = items.size
        items.removeAll { !it.pinned && now - it.createdAt >= 86_400_000L }
        if (items.size != count) revision.value++
        return items.toList()
    }
    @Synchronized fun record(text: String, source: String, now: Long = System.currentTimeMillis()) {
        entries(now)
        if (text.isBlank() || text.toByteArray(Charsets.UTF_8).size > 32768 || ClipboardProtection.reason(text) != null) return
        val pinned = items.firstOrNull { it.text == text && it.source == source }?.pinned ?: false
        items.removeAll { it.text == text && it.source == source }
        items.add(0, ClipboardHistoryEntry(text = text, source = source, createdAt = now, pinned = pinned))
        while (items.size > 100) items.removeAt(items.lastIndex)
        revision.value++
    }
    @Synchronized fun togglePin(id: String) { val index = items.indexOfFirst { it.id == id }; if (index >= 0) { items[index] = items[index].copy(pinned = !items[index].pinned); revision.value++ } }
    @Synchronized fun delete(id: String) { items.removeAll { it.id == id }; revision.value++ }
    @Synchronized fun clear() { items.clear(); revision.value++ }
}
