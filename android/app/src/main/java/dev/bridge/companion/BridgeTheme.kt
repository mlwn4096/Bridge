package dev.bridge.companion

import android.os.Build
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

@Composable
fun BridgeTheme(dark: Boolean, amoled: Boolean, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val base = if (Build.VERSION.SDK_INT >= 31) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else if (dark) darkColorScheme(primary = Color(0xFFB0C6FF), primaryContainer = Color(0xFF224786), background = Color(0xFF101318), surface = Color(0xFF101318))
    else lightColorScheme(primary = Color(0xFF3468E8), primaryContainer = Color(0xFFDEE7FF), background = Color(0xFFF7F8FC), surface = Color(0xFFF7F8FC))
    val colors = if (dark && amoled) base.copy(
        background = Color.Black, surface = Color.Black,
        surfaceDim = Color.Black, surfaceBright = Color(0xFF242424),
        surfaceContainerLowest = Color.Black, surfaceContainerLow = Color(0xFF0D0D0D),
        surfaceContainer = Color(0xFF141414), surfaceContainerHigh = Color(0xFF1B1B1B),
        surfaceContainerHighest = Color(0xFF242424),
        onSurface = Color(0xFFF3F3F3), onSurfaceVariant = Color(0xFFC6C6C6),
        outline = Color(0xFF909090), outlineVariant = Color(0xFF383838)
    ) else base
    MaterialTheme(colorScheme = colors, shapes = Shapes(
        extraSmall = RoundedCornerShape(8.dp), small = RoundedCornerShape(12.dp),
        medium = RoundedCornerShape(20.dp), large = RoundedCornerShape(28.dp), extraLarge = RoundedCornerShape(32.dp)
    ), content = content)
}
