package dev.bridge.companion

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

/** One connection owns this queue: bounded read-ahead, strict wire order, no
 * destination finalization before preceding chunks have been consumed. */
class OrderedReceivePipeline(
    scope: CoroutineScope,
    capacity: Int = 16,
    private val consume: (Message) -> Unit,
    private val failed: (Throwable) -> Unit
) {
    private val messages = Channel<Message>(capacity)
    private val worker = scope.launch {
        try { for (message in messages) consume(message) }
        catch (error: CancellationException) { throw error }
        catch (error: Throwable) { failed(error) }
        finally { messages.cancel() }
    }
    suspend fun submit(message: Message) { messages.send(message) }
    suspend fun stop() {
        messages.cancel(); worker.cancel()
        // A synchronous provider write must finish before partial-file cleanup.
        withContext(NonCancellable) { worker.join() }
    }
}
