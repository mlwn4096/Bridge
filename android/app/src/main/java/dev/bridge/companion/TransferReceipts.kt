package dev.bridge.companion

import android.content.SharedPreferences
import org.json.JSONArray

class TransferReceipts(private val preferences: SharedPreferences) {
    @Synchronized private fun records(): List<org.json.JSONObject> = runCatching {
        val source = preferences.getString("completedFileReceiptsV1", "[]").orEmpty()
        require(source.length <= 512_000)
        val array = JSONArray(source)
        (0 until array.length()).map { array.getJSONObject(it) }.filter { it.optLong("date") > System.currentTimeMillis() - 7 * 86_400_000L }.takeLast(500)
    }.getOrDefault(emptyList())
    @Synchronized fun matches(peer: String, id: String, name: String, size: Long, hash: String): Boolean = records().any { it.optString("peer") == peer && it.optString("id") == id && it.optString("name") == name && it.optLong("size") == size && it.optString("hash") == hash }
    @Synchronized fun record(peer: String, id: String, name: String, size: Long, hash: String) {
        val entries = records().filterNot { it.optString("peer") == peer && it.optString("id") == id } + payload("peer" to peer, "id" to id, "name" to name, "size" to size, "hash" to hash, "date" to System.currentTimeMillis())
        preferences.edit().putString("completedFileReceiptsV1", JSONArray(entries.takeLast(500)).toString()).commit()
    }
    @Synchronized fun clear() { preferences.edit().remove("completedFileReceiptsV1").commit() }
}
