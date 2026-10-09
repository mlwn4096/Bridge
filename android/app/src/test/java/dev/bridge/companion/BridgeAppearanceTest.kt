package dev.bridge.companion

import org.junit.Assert.*
import org.junit.Test

class BridgeAppearanceTest {
    @Test fun systemPreferenceFollowsAppearanceChanges() {
        val preference = BridgeAppearance.stored("SYSTEM")
        assertFalse(preference.isDark(false))
        assertTrue(preference.isDark(true))
    }
    @Test fun explicitThemeSurvivesSystemChanges() {
        assertTrue(BridgeAppearance.stored("DARK").isDark(false))
        assertFalse(BridgeAppearance.stored("LIGHT").isDark(true))
    }
    @Test fun missingOrInvalidStoredPreferenceHasSafeDefault() {
        assertEquals(BridgeAppearance.SYSTEM, BridgeAppearance.stored(null))
        assertEquals(BridgeAppearance.SYSTEM, BridgeAppearance.stored("obsolete"))
    }
}
