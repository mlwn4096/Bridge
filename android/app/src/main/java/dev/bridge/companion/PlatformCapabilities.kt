package dev.bridge.companion

/** Advertise only features that can safely execute on this Android version. */
object PlatformCapabilities {
    fun forVersion(api: Int, fullApi: Int = 0): List<String> =
        listOf("binaryFileV1", "receiverProgressV1", "fileFailureV1", "speedProbeV1") +
            (if (api >= 31) listOf("notificationReplyV1") else emptyList()) +
            (if (api >= 36 && fullApi >= 3600001) listOf("directHotspotV1") else emptyList())
}
