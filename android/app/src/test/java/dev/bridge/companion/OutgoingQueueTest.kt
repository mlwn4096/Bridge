package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.io.File
import java.util.UUID

class OutgoingQueueTest {
    private fun entry(directory: File): QueuedFile {
        val id = UUID.randomUUID().toString()
        val bytes = "snapshot".toByteArray()
        File(directory, "$id.payload").writeBytes(bytes)
        return QueuedFile(id, "a".repeat(64), "file.txt", bytes.size.toLong(), sha256(bytes), System.currentTimeMillis())
    }
    @Test fun snapshotsAndPauseSurviveRestartAndCancelRemovesContent() {
        val directory = Files.createTempDirectory("bridge-queue").toFile()
        try {
            val queue = OutgoingQueue(directory); val entry = entry(directory)
            queue.add(entry); queue.update(entry.copy(paused = true, attempts = 2))
            val reopened = OutgoingQueue(directory)
            assertEquals(entry.id, reopened.all().single().id)
            assertTrue(reopened.all().single().paused)
            assertEquals(2, reopened.all().single().attempts)
            assertEquals("snapshot", reopened.payload(entry.id).readText())
            reopened.remove(entry.id)
            assertTrue(reopened.all().isEmpty()); assertFalse(reopened.payload(entry.id).exists())
        } finally { directory.deleteRecursively() }
    }
    @Test fun interruptedPreparationRemovedWithoutRemovingJournaledSnapshot() {
        val directory = Files.createTempDirectory("bridge-queue").toFile()
        try {
            val queue = OutgoingQueue(directory); val entry = entry(directory); queue.add(entry)
            val interrupted = File(directory, UUID.randomUUID().toString() + ".part"); interrupted.writeText("partial")
            val orphan = File(directory, UUID.randomUUID().toString() + ".payload"); orphan.writeText("orphan")
            OutgoingQueue(directory)
            assertFalse(interrupted.exists()); assertFalse(orphan.exists()); assertTrue(queue.payload(entry.id).exists())
        } finally { directory.deleteRecursively() }
    }
    @Test fun corruptOrTraversalJournalFailsClosed() {
        val directory = Files.createTempDirectory("bridge-queue").toFile()
        try {
            File(directory, "queue.json").writeText("broken")
            assertThrows(Exception::class.java) { OutgoingQueue(directory) }
            File(directory, "queue.json").writeText("""[{"id":"../payload","peer":"${"a".repeat(64)}","name":"file","size":0,"hash":"${"b".repeat(64)}","created":0}]""")
            assertThrows(Exception::class.java) { OutgoingQueue(directory) }
        } finally { directory.deleteRecursively() }
    }
    @Test fun failedJournalPauseBlocksPayloadAcrossRestartUntilExplicitResume() {
        val directory = Files.createTempDirectory("bridge-queue").toFile()
        try {
            val queue = OutgoingQueue(directory); val entry = entry(directory); queue.add(entry)
            queue.pauseSnapshot(entry.id)
            val reopened = OutgoingQueue(directory)
            assertEquals(entry.id, reopened.all().single().id)
            assertFalse(reopened.payload(entry.id).exists())
            reopened.resumeSnapshot(entry.id)
            assertEquals("snapshot", reopened.payload(entry.id).readText())
            reopened.pauseSnapshot(entry.id); reopened.remove(entry.id)
            assertFalse(File(directory, "${entry.id}.paused").exists())
        } finally { directory.deleteRecursively() }
    }
    @Test fun rejectionPreservesSnapshotAndCanBeResumedAfterRestart() {
        val directory = Files.createTempDirectory("bridge-rejection").toFile()
        try {
            val queue = OutgoingQueue(directory); val original = entry(directory); queue.add(original)
            val rejected = queue.pauseAfterRejection(original.id, "Receiver busy")!!
            assertTrue(rejected.paused)
            val reopened = OutgoingQueue(directory)
            assertEquals("Receiver busy", reopened.all().single().error)
            assertEquals("snapshot", reopened.payload(original.id).readText())
            assertNull(reopened.pauseAfterRejection(UUID.randomUUID().toString(), "Unknown"))
            reopened.update(rejected.copy(paused = false, error = ""))
            assertFalse(OutgoingQueue(directory).all().single().paused)
        } finally { directory.deleteRecursively() }
    }
    @Test fun receiverFailuresRetainPayloadAndPauseAfterThreeAttemptsAcrossRestarts() {
        val directory = Files.createTempDirectory("bridge-receiver-failure").toFile()
        try {
            var queue = OutgoingQueue(directory); val original = entry(directory); queue.add(original)
            for (attempt in 1..3) {
                val failed = queue.recordFailure(original.id, "Receiver disk full", 1000L)!!
                assertEquals(attempt, failed.attempts)
                assertEquals(attempt == 3, failed.paused)
                assertEquals(1000L + attempt * 15_000L, failed.retryAfter)
                queue = OutgoingQueue(directory)
                assertEquals(failed, queue.all().single())
                assertEquals("snapshot", queue.payload(original.id).readText())
            }
            assertEquals(3, queue.recordFailure(original.id, "Still full")!!.attempts)
            assertNull(queue.recordFailure(UUID.randomUUID().toString(), "Late failure"))
        } finally { directory.deleteRecursively() }
    }
    @Test fun clearRevokesEverySnapshot() {
        val directory = Files.createTempDirectory("bridge-queue").toFile()
        try {
            val queue = OutgoingQueue(directory); val entry = entry(directory); queue.add(entry); queue.clear()
            assertTrue(OutgoingQueue(directory).all().isEmpty()); assertFalse(queue.payload(entry.id).exists())
        } finally { directory.deleteRecursively() }
    }
}
