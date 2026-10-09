package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test

class ClipboardProtectionTest {
    @Test fun detectsVerificationCodesWithoutFlaggingOrdinaryProse() {
        assertEquals("Possible verification code", ClipboardProtection.reason(" 123456 \n"))
        assertNull(ClipboardProtection.reason("Meet at 123456 tomorrow"))
        assertNull(ClipboardProtection.reason("Hello from Pixel"))
    }
    @Test fun identifiesKnownKeyAndCredentialFormats() {
        assertEquals("Private key", ClipboardProtection.reason("-----BEGIN RSA PRIVATE KEY-----\nexample"))
        assertEquals("Possible API key", ClipboardProtection.reason("ghp_" + "a".repeat(24)))
        assertEquals("Possible credential", ClipboardProtection.reason("PASSWORD=example-value"))
        assertEquals("Possible credential", ClipboardProtection.reason("https://example.com/?access_token=example"))
        assertEquals("Possible authentication token", ClipboardProtection.reason("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"))
    }
    @Test fun cardChecksRequireWholeValueAndValidChecksum() {
        assertEquals("Possible payment card", ClipboardProtection.reason("4111 1111 1111 1111"))
        assertNull(ClipboardProtection.reason("4111 1111 1111 1112"))
        assertNull(ClipboardProtection.reason("0000000000000000"))
        assertNull(ClipboardProtection.reason("Example card 4111 1111 1111 1111"))
    }
    @Test fun approvalAllowsOnlyOneExactPayload() {
        val approval = ClipboardConsent("123456")
        assertTrue(approval.consume("123456")); assertFalse(approval.consume("123456"))
    }
    @Test fun alteredPayloadInvalidatesApproval() {
        val approval = ClipboardConsent("123456")
        assertFalse(approval.consume("654321")); assertFalse(approval.consume("123456"))
    }
}
