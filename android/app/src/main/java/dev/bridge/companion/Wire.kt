package dev.bridge.companion

import org.json.JSONObject
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID

data class Message(val type: String, val payload: JSONObject = JSONObject(), val id: String = UUID.randomUUID().toString()) {
    fun encode(): ByteArray {
        val data = JSONObject().put("v", 1).put("type", type).put("id", id).put("payload", payload).toString().toByteArray(StandardCharsets.UTF_8)
        require(data.size <= MAX_FRAME) { "Message too large" }
        return data + byteArrayOf(10)
    }
    companion object {
        const val MAX_FRAME = 131_072
        const val MAX_TEXT = 32_768
        const val CHUNK_SIZE = 32_768
        fun read(input: InputStream): Message? {
            val first = input.read()
            if (first == -1) return null
            if (first == 0) {
                val lengthBytes = readExact(input, 4)
                val length = java.nio.ByteBuffer.wrap(lengthBytes).int
                require(length in 45..(44 + BINARY_CHUNK_SIZE)) { "Invalid binary frame length" }
                val metadata = readExact(input, 44)
                val id = String(metadata, 0, 36, StandardCharsets.US_ASCII)
                require(UUID.fromString(id).toString().equals(id, ignoreCase = true)) { "Invalid transfer UUID" }
                val sequence = java.nio.ByteBuffer.wrap(metadata, 36, 8).long
                require(sequence >= 0) { "Invalid sequence" }
                val bytes = readExact(input, length - 44)
                return Message("_binaryChunk", payload("transferID" to id, "sequence" to sequence, "data" to bytes))
            }
            val frame = java.io.ByteArrayOutputStream()
            frame.write(first)
            while (true) {
                val next = input.read()
                if (next == -1) { require(frame.size() == 0) { "Truncated message" }; return null }
                if (next == 10) break
                require(frame.size() < MAX_FRAME) { "Message too large" }
                frame.write(next)
            }
            val objectValue = JSONObject(frame.toString(StandardCharsets.UTF_8.name()))
            require(objectValue.getInt("v") == 1) { "Incompatible protocol" }
            val type = objectValue.getString("type"); val id = objectValue.getString("id")
            require(type.length <= 64 && id.length <= 128 && type != "_binaryChunk")
            return Message(type, objectValue.getJSONObject("payload"), id)
        }
    }
}
fun payload(vararg values: Pair<String, Any>): JSONObject = JSONObject().apply { values.forEach { put(it.first, it.second) } }
fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
fun validFileName(name: String): Boolean = name.isNotEmpty() && name.toByteArray().size <= 240 && name != "." && name != ".." && name.none { it == '/' || it == '\\' || it.isISOControl() }
fun validHash(hash: String): Boolean = hash.matches(Regex("[0-9a-f]{64}"))
fun validLink(text: String): Boolean = text.toByteArray(StandardCharsets.UTF_8).size <= 8192 && runCatching {
    val uri = java.net.URI(text); uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null
}.getOrDefault(false)
fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).hex()

const val AUTO_RECEIVE_BYTES = 1_000_000_000L
const val MAX_FILE_BYTES = 17_179_869_184L
fun autoReceiveFile(size: Long): Boolean = size >= 0 && size < AUTO_RECEIVE_BYTES

const val BINARY_CHUNK_SIZE = 262_144
private fun readExact(input: InputStream, count: Int): ByteArray {
    val bytes = ByteArray(count)
    var read = 0
    while (read < count) {
        val n = input.read(bytes, read, count - read)
        require(n > 0) { "Truncated binary frame" }
        read += n
    }
    return bytes
}
fun encodeBinaryChunk(id: String, sequence: Long, bytes: ByteArray, count: Int = bytes.size): ByteArray {
    require(id.length == 36 && UUID.fromString(id).toString().equals(id, ignoreCase = true) && sequence >= 0)
    require(count in 1..BINARY_CHUNK_SIZE && count <= bytes.size)
    return java.nio.ByteBuffer.allocate(49 + count).put(0.toByte()).putInt(44 + count)
        .put(id.toByteArray(StandardCharsets.US_ASCII)).putLong(sequence).put(bytes, 0, count).array()
}

fun handoffTitle(raw: String): String {
    val title = raw.filterNot { it.isISOControl() }.take(160).trim()
    return if (ClipboardProtection.reason(title) == null) title else ""
}
