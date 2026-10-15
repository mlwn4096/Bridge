package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test

class DownloadLinksTest {
    @Test fun acceptsOneEmailAndRejectsHeaderInjectionAndRecipientLists() {
        assertTrue(DownloadLinks.validEmail("hello+mac@example.com"))
        for (invalid in listOf("", "no-address", "a@example.com,b@example.com", "a,b@example.com", "a@example.com\r\nBcc:other@example.com", "someone@", "Name <someone@example.com>", "a b@example.com")) {
            assertFalse(invalid, DownloadLinks.validEmail(invalid))
        }
    }
    @Test fun onlyOpensProductionHttpsFormsWithoutEmbeddedCredentials() {
        assertEquals("https://example.n8n.cloud/form/bridge-mac-download", DownloadLinks.productionFormURL(" https://example.n8n.cloud/form/bridge-mac-download "))
        for (invalid in listOf("", "http://example.com/form/test", "javascript:alert(1)", "https://user:password@example.com/form/test", "https://example.com/form-test/test", "https://example.com/form/test#secret")) {
            assertNull(invalid, DownloadLinks.productionFormURL(invalid))
        }
    }
}
