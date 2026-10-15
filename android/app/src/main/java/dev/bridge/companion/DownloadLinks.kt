package dev.bridge.companion

import java.net.URI

object DownloadLinks {
    const val RELEASES = "https://github.com/mlwn4096/Bridge/releases"
    const val COMPLETED_KEY = "companionInstallStepCompleted"
    const val EMAIL_SUBJECT = "Bridge for your computer — download link"
    val emailBody = """
        Your computer and Android phone, on speaking terms.

        Download Bridge for your computer from GitHub:
        $RELEASES

        Open the release's Assets and choose the desktop package for your platform. On macOS, open the .dmg; on Arch Linux, extract the alpha and run its launcher.
        Already have the Android companion? Tap “Already installed?” in both apps, then scan the computer's pairing QR and approve your phone.

        Desktop requirements: see the selected release for macOS or Arch Linux.
        Keep both devices on the same Wi-Fi or hotspot when pairing.

        — Bridge
        https://mlwn.in
    """.trimIndent()

    fun validEmail(value: String): Boolean = value.length in 3..254 &&
        !value.any { it.isWhitespace() || it.isISOControl() } &&
        Regex("^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}$").matches(value)

    fun productionFormURL(raw: String): String? = runCatching {
        val uri = URI(raw.trim())
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.fragment == null)
        require(!uri.path.orEmpty().contains("form-test"))
        uri.toASCIIString()
    }.getOrNull()
}
