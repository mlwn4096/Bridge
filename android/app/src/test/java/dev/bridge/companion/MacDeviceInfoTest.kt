package dev.bridge.companion

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MacDeviceInfoTest {
    @Test fun laptopSnapshotKeepsBatteryAndSystemDetails() {
        val info = parseMacDeviceInfo(JSONObject().put("model", "MacBookPro18,3").put("chip", "Apple M1 Pro")
            .put("storageTotal", 512_000L).put("storageFree", 120_000L).put("memoryTotal", 16_000L)
            .put("batteryPresent", true).put("battery", 74).put("charging", true), 123L)
        assertEquals("Apple M1 Pro", info.chip); assertEquals(74, info.battery); assertTrue(info.charging)
        assertEquals(120_000L, info.storageFree); assertEquals(123L, info.updatedAt)
    }
    @Test fun desktopAndOldPeersDoNotInventBattery() {
        assertNull(parseMacDeviceInfo(JSONObject().put("battery", 0)).battery)
        assertNull(parseMacDeviceInfo(JSONObject().put("batteryPresent", false).put("battery", 100)).battery)
        assertNull(parseMacDeviceInfo(JSONObject().put("batteryPresent", true)).battery)
    }
    @Test fun malformedValuesAreBounded() {
        val info = parseMacDeviceInfo(JSONObject().put("storageTotal", 10).put("storageFree", 99)
            .put("memoryTotal", -7).put("batteryPresent", true).put("battery", 101)
            .put("cores", 999).put("model", "a".repeat(1000)))
        assertEquals(10L, info.storageFree); assertEquals(0L, info.memoryTotal)
        assertNull(info.battery); assertEquals(256, info.cores); assertEquals(120, info.model.length)
    }
}
