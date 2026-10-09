package dev.bridge.companion

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
