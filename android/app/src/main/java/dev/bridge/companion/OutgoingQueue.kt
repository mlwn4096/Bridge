package dev.bridge.companion

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

data class QueuedFile(val id: String, val peer: String, val name: String, val size: Long, val hash: String,
                      val created: Long, val paused: Boolean = false, val attempts: Int = 0,
                      val retryAfter: Long = 0, val error: String = "")

/** App-private snapshots survive service/process recreation; credentials and clipboard never enter this store. */
class OutgoingQueue(directory: File) {
    val directory = directory.apply { check(mkdirs() || isDirectory) }
    private val journal = File(directory, "queue.json")
    private var entries: List<QueuedFile> = emptyList()
    init {
        require(!Files.isSymbolicLink(journal.toPath())) { "Unsafe queue journal" }
        if (journal.exists()) {
            require(journal.length() <= 512_000) { "Transfer queue is too large" }
            val array = JSONArray(journal.inputStream().bufferedReader().use { it.readText() })
            require(array.length() <= 100)
            entries = (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                QueuedFile(item.getString("id"), item.getString("peer"), item.getString("name"), item.getLong("size"), item.getString("hash"), item.getLong("created"), item.optBoolean("paused"), item.optInt("attempts"), item.optLong("retryAfter"), item.optString("error")).also {
                    require(UUID.fromString(it.id).toString() == it.id && validHash(it.peer) && validFileName(it.name) && it.size in 0..MAX_FILE_BYTES && validHash(it.hash))
                }
            }
            require(entries.map { it.id }.distinct().size == entries.size)
        }
        // A killed preparation never becomes a queued file without its journal entry.
        directory.listFiles()?.filter { it.name.endsWith(".part") || (it.name.endsWith(".payload") && entries.none { entry -> it.name == entry.id + ".payload" }) }?.forEach { it.delete() }
    }
    @Synchronized fun all(): List<QueuedFile> = entries.toList()
    fun payload(id: String): File { require(UUID.fromString(id).toString() == id); return File(directory, "$id.payload") }
    fun pauseSnapshot(id: String) {
        val source = payload(id); val paused = File(directory, "$id.paused")
        if (source.exists()) Files.move(source.toPath(), paused.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
    fun resumeSnapshot(id: String) {
        val paused = File(directory, "$id.paused")
        if (paused.exists()) Files.move(paused.toPath(), payload(id).toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
    @Synchronized fun add(entry: QueuedFile) {
        require(entries.size < 100 && entries.none { it.id == entry.id }) { "The queue holds up to 100 files" }
        require(payload(entry.id).isFile && payload(entry.id).length() == entry.size)
        persist(entries + entry)
    }
    @Synchronized fun update(entry: QueuedFile) { persist(entries.map { if (it.id == entry.id) entry else it }) }
    @Synchronized fun recordFailure(id: String, reason: String, now: Long = System.currentTimeMillis()): QueuedFile? {
        val entry = entries.firstOrNull { it.id == id } ?: return null
        val attempts = (entry.attempts.coerceIn(0, 3) + 1).coerceAtMost(3)
        val failed = entry.copy(attempts = attempts, paused = entry.paused || attempts >= 3,
            retryAfter = now + attempts * 15_000L, error = reason.take(240))
        update(failed)
        return failed
    }
    @Synchronized fun pauseAfterRejection(id: String, reason: String): QueuedFile? {
        val entry = entries.firstOrNull { it.id == id } ?: return null
        val paused = entry.copy(paused = true, error = reason.take(240))
        update(paused)
        return paused
    }
    @Synchronized fun remove(id: String) { persist(entries.filter { it.id != id }); payload(id).delete(); File(directory, "$id.paused").delete() }
    @Synchronized fun clear() { val previous = entries; persist(emptyList()); previous.forEach { payload(it.id).delete(); File(directory, "${it.id}.paused").delete() } }
    private fun persist(values: List<QueuedFile>) {
        val array = JSONArray()
        values.forEach { entry -> array.put(JSONObject().put("id", entry.id).put("peer", entry.peer).put("name", entry.name).put("size", entry.size).put("hash", entry.hash).put("created", entry.created).put("paused", entry.paused).put("attempts", entry.attempts).put("retryAfter", entry.retryAfter).put("error", entry.error)) }
        val temporary = File(directory, "journal-${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(temporary).use { output -> output.write(array.toString().toByteArray()); output.fd.sync() }
            Files.move(temporary.toPath(), journal.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            entries = values
        } finally { temporary.delete() }
    }
}
