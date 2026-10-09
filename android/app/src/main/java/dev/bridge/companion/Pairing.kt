package dev.bridge.companion

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class Pairing(val host: String, val port: Int, val fingerprint: String, val token: String,
                   val name: String, val service: String, val deviceID: String, val credential: String) {
    fun json(): JSONObject = payload("host" to host, "port" to port, "fingerprint" to fingerprint,
        "token" to token, "name" to name, "service" to service, "deviceID" to deviceID, "credential" to credential)
    companion object {
        fun fromURL(raw: String): Pairing {
            require(raw.length <= 4096) { "Pairing link is too long" }
            val uri = URI(raw.trim())
            require(uri.scheme == "bridge" && uri.host == "pair" && uri.userInfo == null && uri.port == -1 && uri.fragment == null && uri.path.orEmpty().isEmpty()) { "Paste a Bridge pairing link from your Mac" }
            val fields = uri.rawQuery?.split("&") ?: error("Missing pairing details")
            val query = fields.map {
                val parts = it.split("=", limit = 2)
                // This is a URI query, not form data: a literal '+' is part of a
                // base64 pairing token and must not become a space.
                URLDecoder.decode(parts[0].replace("+", "%2B"), "UTF-8") to
                    URLDecoder.decode(parts.getOrElse(1) { "" }.replace("+", "%2B"), "UTF-8")
            }
            require(query.map { it.first }.distinct().size == query.size) { "Duplicate pairing details" }
            val values = query.toMap()
            val host = values["host"].orEmpty(); val port = values["port"]?.toIntOrNull() ?: 0
            require(host.matches(Regex("[A-Za-z0-9.:%_-]{1,253}")) && port in 1..65535) { "Invalid Mac address" }
            val fingerprint = values["fingerprint"].orEmpty()
            require(validHash(fingerprint)) { "Invalid certificate fingerprint" }
            val token = values["token"].orEmpty()
            require(java.util.Base64.getDecoder().decode(token).size == 32) { "Invalid pairing token" }
            val secret = ByteArray(32).also { SecureRandom().nextBytes(it) }
            return Pairing(host, port, fingerprint, token, values["name"].orEmpty().take(80), values["service"].orEmpty().take(80),
                UUID.randomUUID().toString(), java.util.Base64.getEncoder().encodeToString(secret))
        }
        fun fromJSON(value: JSONObject): Pairing {
            val peer = Pairing(value.getString("host"), value.getInt("port"), value.getString("fingerprint"),
                value.optString("token"), value.getString("name"), value.optString("service"), value.getString("deviceID"), value.getString("credential"))
            require(peer.host.matches(Regex("[A-Za-z0-9.:%_-]{1,253}")) && peer.port in 1..65535 && validHash(peer.fingerprint))
            require(peer.token.isEmpty() && UUID.fromString(peer.deviceID).toString() == peer.deviceID)
            require(java.util.Base64.getDecoder().decode(peer.credential).size == 32)
            return peer
        }
    }
}

class SecureStore(context: Context) {
    private val prefs = context.getSharedPreferences("bridge-secure", Context.MODE_PRIVATE)
    private val alias = "bridge-device-credentials"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun save(pairing: Pairing) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(pairing.copy(token = "").json().toString().toByteArray())
        check(prefs.edit().putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("pairing", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()) { "Could not save pairing" }
    }
    fun load(): Pairing? {
        val value = prefs.getString("pairing", null) ?: return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)))
            Pairing.fromJSON(JSONObject(String(cipher.doFinal(Base64.decode(value, Base64.NO_WRAP)))))
        }.getOrNull()
    }
    fun clear() { check(prefs.edit().clear().commit()) }
}
