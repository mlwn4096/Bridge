package dev.bridge.companion

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import org.json.JSONArray
import java.util.UUID

/** Only documents enumerated beneath the user-granted tree may be requested. */
class PhoneFiles(private val context: Context) {
    private data class Entry(val uri: Uri, val directory: Boolean)
    private var tree = ""
    private val entries = LinkedHashMap<String, Entry>()
    @Synchronized fun reset() { entries.clear(); tree = "" }
    @Synchronized fun list(folder: String, requestID: String, offset: Int = 0): Message {
        return try {
            val configured = context.getSharedPreferences("bridge", Context.MODE_PRIVATE).getString("phoneFilesTree", "") ?: ""
            if (configured != tree) { entries.clear(); tree = configured }
            check(tree.isNotEmpty()) { "Choose a shared folder in Bridge on Android: Settings → Phone files." }
            check(offset in 0..10000) { "Invalid browser page. Open the shared folder again." }
            check(requestID.length <= 80 && folder.length <= 80) { "Invalid browser request." }
            if (folder.isEmpty() && offset == 0) entries.clear()
            val root = Uri.parse(tree)
            val parent = if (folder.isEmpty()) DocumentsContract.buildDocumentUriUsingTree(root, DocumentsContract.getTreeDocumentId(root))
                else entries[folder]?.takeIf { it.directory }?.uri ?: error("Folder expired. Open the shared folder again.")
            check(context.contentResolver.persistedUriPermissions.any { it.uri == root && it.isReadPermission }) { "Folder access was removed. Choose the folder again on Android." }
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(root, DocumentsContract.getDocumentId(parent))
            val result = JSONArray()
            var nextOffset = -1
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE)
            context.contentResolver.query(children, columns, null, null, null)?.use { cursor ->
                var row = 0
                while (cursor.moveToNext()) {
                    if (row++ < offset) continue
                    if (result.length() >= 60) { nextOffset = offset + result.length(); break }
                    check(entries.size < 10000) { "File browser limit reached. Open the shared folder again." }
                    val uri = DocumentsContract.buildDocumentUriUsingTree(root, cursor.getString(0))
                    val directory = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                    val token = entries.entries.firstOrNull { it.value.uri == uri }?.key ?: UUID.randomUUID().toString()
                    entries[token] = Entry(uri, directory)
                    result.put(payload("id" to token, "name" to (cursor.getString(1) ?: "Untitled").take(240), "directory" to directory, "size" to cursor.getLong(3).coerceAtLeast(0)))
                }
            } ?: error("Unable to read this folder.")
            Message("phoneFiles", payload("requestID" to requestID, "folder" to folder, "entries" to result, "offset" to offset, "nextOffset" to nextOffset)).also { it.encode() }
        } catch (error: Exception) {
            Message("phoneFiles", payload("requestID" to requestID, "folder" to folder, "error" to (error.message ?: "Unable to browse files")))
        }
    }
    @Synchronized fun file(token: String): Uri {
        val configured = context.getSharedPreferences("bridge", Context.MODE_PRIVATE).getString("phoneFilesTree", "") ?: ""
        check(configured == tree && configured.isNotEmpty()) { "Shared folder changed. Refresh the browser." }
        check(context.contentResolver.persistedUriPermissions.any { it.uri.toString() == tree && it.isReadPermission }) { "Folder access was removed." }
        return entries[token]?.takeIf { !it.directory }?.uri ?: error("File expired. Refresh the browser.")
    }
}
