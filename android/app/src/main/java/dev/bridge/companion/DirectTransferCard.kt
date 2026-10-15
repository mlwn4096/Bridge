package dev.bridge.companion

import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun DirectTransferCard(ui: UIState, start: () -> Unit) {
    Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Transfer connection", style = MaterialTheme.typography.titleMedium)
            Text(if (ui.directMode) ui.directStatus else "Direct transfer uses a temporary phone hotspot to bypass your router. Join it in your Mac’s Wi-Fi settings.",
                style = MaterialTheme.typography.bodyMedium)
            if (ui.directMode) Text(ui.directSSID, style = MaterialTheme.typography.labelLarge)
            if (!ui.directMode && ui.directStatus.isNotEmpty()) Text(ui.directStatus, style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (ui.directMode) OutlinedButton(onClick = { BridgeService.instance?.stopDirectTransfer() }, enabled = !ui.speedCheckRunning) { Text("End direct mode") }
                else OutlinedButton(onClick = start, enabled = ui.connected && ui.directSupported && !ui.speedCheckRunning) { Text("Direct transfer") }
                TextButton(onClick = { BridgeService.instance?.requestSpeedCheck() }, enabled = ui.connected && ui.speedCheckSupported && !ui.speedCheckRunning && (!ui.directMode || ui.directConnected)) { Text("Check speed") }
            }
            if ((Build.VERSION.SDK_INT < 36 || Build.VERSION.SDK_INT_FULL < Build.VERSION_CODES_FULL.BAKLAVA_1)) Text("Automatic direct setup needs Android 16.1 or later. You can still connect your Mac to your phone’s hotspot manually.", style = MaterialTheme.typography.bodySmall)
            else if (ui.connected && !ui.directSupported) Text("Update Bridge on your Mac to enable Direct transfer.", style = MaterialTheme.typography.bodySmall)
            if (ui.speedCheckStatus.isNotEmpty()) Text(ui.speedCheckStatus, style = MaterialTheme.typography.bodySmall)
            if (ui.speedCheckRunning) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}
