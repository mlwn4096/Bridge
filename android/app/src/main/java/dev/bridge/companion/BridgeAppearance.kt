package dev.bridge.companion

/** Local appearance only. Does not affect connection or content retention. */
enum class BridgeAppearance(val label: String) {
    SYSTEM("Follow system"), LIGHT("Light"), DARK("Dark");
    fun isDark(systemDark: Boolean) = this == DARK || (this == SYSTEM && systemDark)
    companion object {
        fun stored(value: String?) = entries.firstOrNull { it.name == value } ?: SYSTEM
    }
}
