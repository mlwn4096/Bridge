package dev.bridge.companion

/** Conservative heuristics, matching Mac behavior; not a guarantee of secret detection. */
object ClipboardProtection {
    private val patterns = listOf(
        Regex("-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----") to "Private key",
        Regex("\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b|\\bgh[pousr]_[A-Za-z0-9]{20,}\\b|\\bgithub_pat_[A-Za-z0-9_]{20,}\\b|\\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\\b") to "Possible API key",
        Regex("\\b(?:password|passwd|api[_-]?key|access[_-]?token|secret)\\s*[:=]\\s*\\S+", RegexOption.IGNORE_CASE) to "Possible credential",
        Regex("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b") to "Possible authentication token",
        Regex("^[0-9]{4,8}$") to "Possible verification code"
    )
    fun reason(text: String): String? {
        val value = text.trim()
        patterns.firstOrNull { it.first.containsMatchIn(value) }?.let { return it.second }
        if (value.matches(Regex("^[0-9 -]+$"))) {
            val digits = value.filter { it in '0'..'9' }.map { it - '0' }
            if (digits.size in 13..19 && digits.toSet().size > 1) {
                val sum = digits.asReversed().mapIndexed { index, digit ->
                    val number = if (index % 2 == 1) digit * 2 else digit
                    if (number > 9) number - 9 else number
                }.sum()
                if (sum % 10 == 0) return "Possible payment card"
            }
        }
        return null
    }
}

/** In-memory, exact-payload approval. Never stored and never reusable. */
class ClipboardConsent(private var approvedText: String?) {
    @Synchronized fun consume(text: String): Boolean {
        val approved = approvedText
        approvedText = null
        return approved != null && approved == text
    }
}
