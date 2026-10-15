package dev.bridge.companion

import org.json.JSONObject
import java.util.UUID

/** Discovery is only a route hint. The existing pinned TLS handshake still authenticates it. */
data class DirectSession(val id: String, val ssid: String, val password: String) {
    fun offer() = payload("sessionID" to id, "ssid" to ssid, "password" to password)
    companion object {
        const val DISCOVERY_PORT = 38474
        fun create(): DirectSession = DirectSession(UUID.randomUUID().toString(),
            "Bridge-${UUID.randomUUID().toString().take(8)}", UUID.randomUUID().toString().replace("-", "").take(24))
    }
    fun endpoint(data: ByteArray, host: String): Pair<String, Int>? = runCatching {
        require(data.size in 1..1024 && privateIPv4(host))
        val body = JSONObject(String(data, Charsets.UTF_8))
        require(body.getString("type") == "bridgeDirectV1" && body.getString("sessionID") == id)
        val port = body.getInt("port"); require(port in 1..65535)
        host to port
    }.getOrNull()
}

internal fun privateIPv4(host: String): Boolean {
    val parts = host.split('.').map { it.toIntOrNull() ?: return false }
    if (parts.size != 4 || parts.any { it !in 0..255 } || parts[3] == 0 || parts[3] == 255) return false
    return parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) || (parts[0] == 192 && parts[1] == 168)
}

const val SPEED_PROBE_BYTES = 32L * 1024 * 1024

/** A bounded, ordered memory sink. Never creates a file or a transfer receipt. */
class SpeedProbe(val id: String, val size: Long) {
    var received = 0L; private set
    private var sequence = 0L
    private var firstNanos: Long? = null
    private var lastNanos = 0L
    init { require(UUID.fromString(id).toString().equals(id, true) && size == SPEED_PROBE_BYTES) }
    fun append(chunkID: String, chunkSequence: Long, data: ByteArray, nowNanos: Long) {
        require(chunkID == id && chunkSequence == sequence && data.isNotEmpty() && data.size <= BINARY_CHUNK_SIZE)
        require(received + data.size <= size && nowNanos >= lastNanos)
        if (firstNanos == null) firstNanos = nowNanos
        received += data.size; sequence++; lastNanos = nowNanos
    }
    fun finish(): Double {
        require(received == size)
        return (lastNanos - requireNotNull(firstNanos)).coerceAtLeast(1) / 1_000_000_000.0
    }
}
