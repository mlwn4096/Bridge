package dev.bridge.companion

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderArchiveTest {
    @Test fun rawFileSourcesCannotReadPrivateFilesOrFollowSymlinks() {
        val root = java.nio.file.Files.createTempDirectory("bridge-folder-source").toFile().canonicalFile
        try {
            val cache = java.io.File(root, "cache").apply { mkdir() }
            val stage = java.io.File(cache, "bridge-folder-${java.util.UUID.randomUUID()}").apply { mkdir() }
            val archive = java.io.File(stage, "folder.zip").apply { writeText("zip") }
            val privateFile = java.io.File(root, "private-state.json").apply { writeText("private") }
            assertTrue(FolderArchive.isStagedSource(archive, cache))
            val cacheAlias = java.io.File(root, "cache-alias")
            java.nio.file.Files.createSymbolicLink(cacheAlias.toPath(), cache.toPath())
            assertTrue(FolderArchive.isStagedSource(java.io.File(java.io.File(cacheAlias, stage.name), archive.name), cacheAlias))
            assertFalse(FolderArchive.isStagedSource(privateFile, cache))
            assertFalse(FolderArchive.isStagedSource(java.io.File(cache, "folder.zip").apply { writeText("zip") }, cache))
            val link = java.io.File(stage, "linked.zip")
            java.nio.file.Files.createSymbolicLink(link.toPath(), privateFile.toPath())
            assertFalse(FolderArchive.isStagedSource(link, cache))
            assertFalse(FolderArchive.isStagedSource(java.io.File(stage, "../${stage.name}/folder.zip"), cache))
        } finally { root.deleteRecursively() }
    }

    @Test fun rejectsUnsafeComponents() {
        listOf("", ".", "..", "a/b", "a\\b", "a:b", "a\n", "\u0000", "x".repeat(256), "🌉".repeat(64)).forEach {
            assertFalse("Unsafe component accepted: $it", FolderArchive.validComponent(it))
        }
    }
    @Test fun permitsNormalFolderNames() {
        listOf("Photos", "holiday 2026", "🌉", "a..b", "-folder").forEach {
            assertTrue(FolderArchive.validComponent(it))
        }
    }
}
