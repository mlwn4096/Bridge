package dev.bridge.companion

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ReceivePipelineTest {
    @Test fun completionCannotOvertakeQueuedFileChunks() = runBlocking {
        val events = mutableListOf<Int>()
        val complete = CompletableDeferred<Unit>()
        val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val pipeline = OrderedReceivePipeline(workerScope, capacity = 4, consume = { message ->
            if (message.type == "fileComplete") complete.complete(Unit)
            else events.add(message.payload.getInt("sequence"))
        }, failed = { complete.completeExceptionally(it) })
        try {
            repeat(64) { pipeline.submit(Message("chunk", payload("sequence" to it))) }
            pipeline.submit(Message("fileComplete"))
            withTimeout(5000) { complete.await() }
            assertEquals((0 until 64).toList(), events)
        } finally { pipeline.stop(); workerScope.cancel() }
    }

    @Test fun slowWriterBackpressuresReaderAtCapacity() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val submitted = AtomicInteger()
        val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val pipeline = OrderedReceivePipeline(workerScope, capacity = 2, consume = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
        }, failed = {})
        var producer: Job? = null
        try {
            pipeline.submit(Message("chunk")); submitted.incrementAndGet()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            producer = launch {
                repeat(3) { pipeline.submit(Message("chunk")); submitted.incrementAndGet() }
            }
            withTimeout(5000) { while (submitted.get() < 3) yield() }
            // One consumed-but-blocked message, two buffered messages; fourth waits.
            assertEquals(3, submitted.get()); assertTrue(producer.isActive)
            release.countDown(); withTimeout(5000) { producer.join() }
            assertEquals(4, submitted.get())
        } finally { release.countDown(); producer?.cancelAndJoin(); pipeline.stop(); workerScope.cancel() }
    }

    @Test fun shutdownWaitsForInProgressWriteBeforeCleanup() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val writeFinished = CompletableDeferred<Unit>()
        val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val pipeline = OrderedReceivePipeline(workerScope, consume = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); writeFinished.complete(Unit)
        }, failed = {})
        try {
            pipeline.submit(Message("chunk")); assertTrue(entered.await(5, TimeUnit.SECONDS))
            val stopping = async { pipeline.stop() }
            yield(); assertFalse(stopping.isCompleted)
            release.countDown(); withTimeout(5000) { stopping.await() }
            assertTrue(writeFinished.isCompleted)
        } finally { release.countDown(); pipeline.stop(); workerScope.cancel() }
    }
}
