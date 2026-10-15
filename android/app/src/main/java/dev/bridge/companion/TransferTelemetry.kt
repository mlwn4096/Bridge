package dev.bridge.companion

data class TransferTimings(val started: Long? = null, val phase: String = "", val entered: Long = 0,
                           val milliseconds: Map<String, Long> = emptyMap(), val total: Long? = null) {
    fun transition(state: String, now: Long): TransferTimings {
        val next = when (state) {
            "Preparing" -> "preparation"
            "Waiting for phone", "Waiting for computer", "Accept to receive" -> "waiting"
            "Sending", "Receiving" -> "transfer"
            "Finishing", "Verifying" -> "finish"
            "Complete" -> "complete"
            else -> return this
        }
        if (next == "preparation" && phase != next) return TransferTimings(now, next, now)
        if (started == null && next == "transfer") return TransferTimings(now, next, now)
        if (started == null || total != null || now < entered || next == phase) return this
        return copy(phase = next, entered = now, milliseconds = milliseconds + (phase to ((milliseconds[phase] ?: 0) + now - entered)),
            total = if (next == "complete") now - started else null)
    }
    fun summary(): String? = total?.let {
        "Total %.1fs · preparation %.1fs · waiting %.1fs · transfer %.1fs · finish %.1fs".format(
            it / 1000.0, (milliseconds["preparation"] ?: 0) / 1000.0, (milliseconds["waiting"] ?: 0) / 1000.0,
            (milliseconds["transfer"] ?: 0) / 1000.0, (milliseconds["finish"] ?: 0) / 1000.0)
    }
}

class TransferRateEstimator(val total: Long, started: Long) {
    var bytes: Long = 0; private set
    var rate: Double = 0.0; private set
    private var lastTime = started
    fun record(received: Long, now: Long): Boolean {
        if (total < 0 || received < bytes || received > total || now <= lastTime) return false
        val sample = (received - bytes) * 1000.0 / (now - lastTime)
        rate = if (rate == 0.0) sample else 0.25 * sample + 0.75 * rate
        bytes = received; lastTime = now
        return true
    }
}
fun transferEta(size: Long, progress: Float, speed: Double): String? {
    if (size <= 0 || !progress.isFinite() || progress < 0 || progress >= 1 || !speed.isFinite() || speed <= 0) return null
    val seconds = kotlin.math.ceil(size * (1.0 - progress) / speed)
    if (!seconds.isFinite() || seconds > 604800) return null
    val value = seconds.toLong().coerceAtLeast(1)
    return when {
        value < 60 -> "~${value}s left"
        value < 3600 -> "~${(value + 59) / 60} min left"
        else -> "~${(value + 3599) / 3600} hr left"
    }
}
