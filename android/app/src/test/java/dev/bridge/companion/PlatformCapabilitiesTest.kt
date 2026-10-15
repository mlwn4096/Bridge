package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test

class PlatformCapabilitiesTest {
    @Test fun android10And11KeepTransfersWithoutUnsafeNotificationReplies() {
        for (api in 29..30) {
            val capabilities = PlatformCapabilities.forVersion(api)
            assertTrue(capabilities.containsAll(listOf("binaryFileV1", "receiverProgressV1", "fileFailureV1", "speedProbeV1")))
            assertFalse(capabilities.contains("notificationReplyV1"))
            assertFalse(capabilities.contains("directHotspotV1"))
        }
    }
    @Test fun notificationRepliesStartAtAndroid12() {
        for (api in 31..35) {
            assertTrue(PlatformCapabilities.forVersion(api).contains("notificationReplyV1"))
            assertFalse(PlatformCapabilities.forVersion(api).contains("directHotspotV1"))
        }
    }
    @Test fun configuredHotspotRequiresTheMinorReleaseNotJustAndroid16() {
        assertFalse(PlatformCapabilities.forVersion(36, 3600000).contains("directHotspotV1"))
        assertTrue(PlatformCapabilities.forVersion(36, 3600001).contains("directHotspotV1"))
        assertTrue(PlatformCapabilities.forVersion(37, 3700000).contains("directHotspotV1"))
    }
}
