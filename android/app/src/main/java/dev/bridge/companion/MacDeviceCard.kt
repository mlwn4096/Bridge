package dev.bridge.companion

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable fun MacDeviceCard(ui: UIState, name: String, reconnect: () -> Unit) {
    val context = LocalContext.current
    val info = ui.macInfo
    var expanded by rememberSaveable { mutableStateOf(false) }
    fun bytes(value: Long) = android.text.format.Formatter.formatFileSize(context, value)
    val storageUsed = info?.let { (it.storageTotal - it.storageFree).coerceAtLeast(0) } ?: 0
    val storageFraction by animateFloatAsState(
        targetValue = if (info != null && info.storageTotal > 0) storageUsed.toFloat() / info.storageTotal else 0f,
        animationSpec = tween(350), label = "Mac storage")
    Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.fillMaxWidth().animateContentSize(tween(220)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.secondaryContainer) {
                    Icon(Icons.Outlined.LaptopMac, null, Modifier.padding(14.dp).size(28.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(if (ui.connected) "${if (ui.status.contains("USB")) "USB" else "Wi-Fi"} · Encrypted connection" else ui.status,
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (!ui.connected) FilledTonalIconButton(onClick = reconnect) { Icon(Icons.Outlined.Sync, "Reconnect to Mac") }
            }
            if (info == null) {
                Text(if (ui.connected) "Getting your Mac’s details…" else "Connect to see battery, storage and system details.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Surface(Modifier.weight(1f), shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(if (info.charging) Icons.Outlined.BatteryChargingFull else if (info.battery != null) Icons.Outlined.BatteryFull else Icons.Outlined.Power, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                            Text(info.battery?.let { "$it%" } ?: "AC power", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                            Text(if (info.charging) "Charging" else if (info.onAC || info.battery == null) "Plugged in" else "On battery", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Surface(Modifier.weight(1f), shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Outlined.Memory, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                            Text(if (info.memoryTotal > 0) bytes(info.memoryTotal) else "—", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                            Text("Unified memory", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (info.storageTotal > 0) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Storage", style = MaterialTheme.typography.labelLarge)
                        Text("${bytes(info.storageFree)} free", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    LinearProgressIndicator(progress = { storageFraction.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(6.dp))
                    Text("${bytes(storageUsed)} used of ${bytes(info.storageTotal)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) {
                    Text(if (expanded) "Less detail" else "System details")
                    Spacer(Modifier.width(6.dp))
                    Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
                }
                if (expanded) {
                    for ((label, value) in listOf("Model" to info.model, "Software" to info.os, "Chip" to info.chip,
                        "Processor" to if (info.cores > 0) "${info.cores} cores" else "")) {
                        if (value.isNotBlank()) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(label, Modifier.width(80.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(value, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                Text(if (ui.connected) "Updates while connected" else "Offline · last updated ${java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(info.updatedAt))}",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
