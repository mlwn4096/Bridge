package dev.bridge.companion

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.FilterOutputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Folder ZIP creation using only the specific directory grant supplied by Android's picker. */
object FolderArchive {
    const val MAX_ENTRIES = 10_000
    private const val MAX_DEPTH = 128
    private const val MAX_BYTES = 17_179_869_184L

    fun validComponent(name: String): Boolean = name.isNotEmpty() && name != "." && name != ".." &&
        name.toByteArray(Charsets.UTF_8).size <= 255 && name.none { it == '/' || it == '\\' || it == ':' || Character.isISOControl(it) }

    /** Blocking: call on IO dispatcher. Caller deletes file after send, failure, or cancellation. */
    fun create(context: Context, tree: Uri, cancelled: () -> Boolean = { false }): File {
        require(DocumentsContract.isTreeUri(tree)) { "Choose a folder using the system picker" }
        val resolver = context.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        fun documentName(uri: Uri): String {
            resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                require(cursor.moveToFirst()) { "Folder is unavailable" }
                require(cursor.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR) { "Choose a folder" }
                return cursor.getString(0).also { require(validComponent(it)) { "Folder has an unsafe name" } }
            }
            error("Folder is unavailable")
        }
        val rootName = documentName(rootUri)
        val directory = File(context.cacheDir, "bridge-folder-${UUID.randomUUID()}")
        check(directory.mkdir()) { "Could not prepare folder cache" }
        val archive = File(directory, "$rootName.zip")
        var success = false
        var entries = 0
        var sourceBytes = 0L
        val visited = hashSetOf(rootId)
        fun checkCancellation() { if (cancelled()) throw CancellationException("Folder preparation cancelled") }
        try {
            ZipOutputStream(BoundedOutput(archive.outputStream(), MAX_BYTES)).use { zip ->
                fun addDirectory(documentId: String, path: String, depth: Int) {
                    checkCancellation()
                    require(depth <= MAX_DEPTH) { "Folder is nested too deeply" }
                    require(path.toByteArray(Charsets.UTF_8).size <= 4096) { "Folder path is too long" }
                    require(++entries <= MAX_ENTRIES) { "Folders may contain at most 10,000 files and directories" }
                    zip.putNextEntry(ZipEntry("$path/")); zip.closeEntry()
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
                    val names = HashSet<String>()
                    resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            checkCancellation()
                            val id = cursor.getString(0)
                            val name = cursor.getString(1)
                            require(validComponent(name) && names.add(name)) { "Folder contains an unsafe or duplicate name" }
                            require(visited.add(id)) { "Folder contains a repeated or cyclic entry" }
                            val childPath = "$path/$name"
                            require(childPath.toByteArray(Charsets.UTF_8).size <= 4096) { "Folder path is too long" }
                            if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                                addDirectory(id, childPath, depth + 1)
                            } else {
                                require(++entries <= MAX_ENTRIES) { "Folders may contain at most 10,000 files and directories" }
                                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                                zip.putNextEntry(ZipEntry(childPath))
                                val input = resolver.openInputStream(uri) ?: error("A folder file is unavailable")
                                input.use {
                                    val buffer = ByteArray(128 * 1024)
                                    while (true) {
                                        checkCancellation()
                                        val size = it.read(buffer)
                                        if (size < 0) break
                                        if (size == 0) continue
                                        sourceBytes += size
                                        require(sourceBytes <= MAX_BYTES) { "Folder exceeds 16 GiB" }
                                        zip.write(buffer, 0, size)
                                    }
                                }
                                zip.closeEntry()
                            }
                        }
                    } ?: error("Folder contents are unavailable")
                }
                addDirectory(rootId, rootName, 0)
            }
            checkCancellation()
            success = true
            return archive
        } finally { if (!success) directory.deleteRecursively() }
    }

    /** Raw file URIs are internal folder snapshots, never arbitrary app-private paths. */
    fun isStagedSource(archive: File, cacheDirectory: File): Boolean = runCatching {
        val parent = archive.parentFile ?: return@runCatching false
        val expected = File(File(cacheDirectory.canonicalFile, parent.name), archive.name)
        archive.isFile && archive.isAbsolute && archive.toPath().normalize() == archive.toPath() && archive.canonicalFile == expected &&
            parent.parentFile?.canonicalFile == cacheDirectory.canonicalFile &&
            parent.name.matches(Regex("bridge-folder-[0-9a-fA-F-]{36}"))
    }.getOrDefault(false)

    fun remove(archive: File) {
        val parent = archive.parentFile ?: return
        if (parent.name.startsWith("bridge-folder-")) parent.deleteRecursively()
    }

    private class BoundedOutput(output: OutputStream, private val limit: Long) : FilterOutputStream(output) {
        private var count = 0L
        override fun write(value: Int) { checkSize(1); out.write(value) }
        override fun write(bytes: ByteArray, offset: Int, length: Int) { checkSize(length); out.write(bytes, offset, length) }
        private fun checkSize(length: Int) {
            count += length
            require(count <= limit) { "Folder ZIP exceeds 16 GiB" }
        }
    }
}
