package dev.bridge.companion

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

data class Transfer(val id: String, val name: String, val size: Long, val incoming: Boolean,
                    val status: String = "Waiting", val progress: Float = 0f, val path: String? = null, val bytesPerSecond: Double = 0.0, val lastProgressElapsed: Long = 0, val failureReason: String = "", val timings: TransferTimings = TransferTimings())
data class MacDeviceInfo(val model: String = "", val os: String = "", val chip: String = "", val cores: Int = 0,
                         val memoryTotal: Long = 0, val storageTotal: Long = 0, val storageFree: Long = 0,
                         val battery: Int? = null, val charging: Boolean = false, val onAC: Boolean = false,
                         val updatedAt: Long = 0)
data class UIState(val status: String = "Not connected", val connected: Boolean = false, val pairing: Boolean = false,
                   val macName: String = "", val macInfo: MacDeviceInfo? = null, val clipboard: String = "", val link: String = "",
                   val transfers: List<Transfer> = emptyList(), val error: String = "", val ringing: Boolean = false,
                   val directSupported: Boolean = false, val directMode: Boolean = false, val directConnected: Boolean = false,
                   val directSSID: String = "", val directStatus: String = "", val speedCheckSupported: Boolean = false,
                   val speedCheckRunning: Boolean = false, val speedCheckStatus: String = "")
object BridgeState {
    val state = MutableStateFlow(UIState())
    fun updateTransfer(id: String, status: String, progress: Float? = null, path: String? = null, bytesPerSecond: Double? = null, failureReason: String? = null) {
        state.update { ui -> ui.copy(transfers = ui.transfers.map {
            if (it.id == id) it.copy(status = status, progress = progress ?: it.progress, path = path ?: it.path, bytesPerSecond = bytesPerSecond ?: it.bytesPerSecond, failureReason = failureReason ?: it.failureReason, lastProgressElapsed = if (progress != null) android.os.SystemClock.elapsedRealtime() else it.lastProgressElapsed,
                timings = it.timings.transition(status, android.os.SystemClock.elapsedRealtime())) else it
        }) }
    }
    fun addTransfer(transfer: Transfer) {
        state.update { ui -> ui.copy(transfers = retainedTransfers(transfer, ui.transfers)) }
    }
}

// Preserve every live transfer even after many short transfers complete. Otherwise
// an active card can disappear and its cancel/receipt state is no longer visible.
internal fun retainedTransfers(new: Transfer, previous: List<Transfer>): List<Transfer> {
    val all = listOf(new) + previous.filter { it.id != new.id }
    var finished = 0
    return all.filter { transfer ->
        if (transfer.status in setOf("Complete", "Cancelled", "Failed")) ++finished <= 50 else true
    }
}

internal fun parseMacDeviceInfo(body: org.json.JSONObject, updatedAt: Long = System.currentTimeMillis()): MacDeviceInfo {
    val total = body.optLong("storageTotal").coerceAtLeast(0)
    return MacDeviceInfo(model = body.optString("model").take(120), os = body.optString("os").take(80),
        chip = body.optString("chip").take(120), cores = body.optInt("cores").coerceIn(0, 256),
        memoryTotal = body.optLong("memoryTotal").coerceAtLeast(0), storageTotal = total,
        storageFree = body.optLong("storageFree").coerceIn(0, total),
        battery = if (body.optBoolean("batteryPresent")) (body.opt("battery") as? Number)?.toInt()?.takeIf { it in 0..100 } else null,
        charging = body.optBoolean("charging"), onAC = body.optBoolean("onAC"), updatedAt = updatedAt)
}
