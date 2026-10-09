package dev.bridge.companion

/** Shared bounds; reply text is never journaled or retried. */
object NotificationReplyPolicy {
    const val MAX_BYTES = 4096
    const val ACTION_LIFETIME_MS = 5 * 60_000L
    fun validText(text: String): Boolean = text.isNotBlank() && '\u0000' !in text && text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES
    fun fresh(issuedAt: Long, now: Long): Boolean = now >= issuedAt && now - issuedAt < ACTION_LIFETIME_MS
}
data class NotificationReplyOutcome(val accepted: Boolean, val message: String)

/** Single-use lease is consumed before dispatch; rejection cannot replay a send. */
class NotificationActionLease(private val issuedAt: Long) {
    private var consumed = false
    @Synchronized fun usable(now: Long): Boolean = !consumed && NotificationReplyPolicy.fresh(issuedAt, now)
    @Synchronized fun consume(now: Long): Boolean {
        if (!usable(now)) return false
        consumed = true
        return true
    }
}
