package dev.bridge.companion

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@Composable
fun CompanionDownloadScreen(onContinue: () -> Unit) {
    val context = LocalContext.current
    val emailFormURL = stringResource(R.string.bridge_download_email_form_url)
    val emailForm = remember(emailFormURL) { DownloadLinks.productionFormURL(emailFormURL) }
    var showEmail by remember { mutableStateOf(false) }
    var email by remember { mutableStateOf("") }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.surface,
        bottomBar = {
            Surface {
                TextButton(onClick = onContinue, modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 8.dp)) {
                    Text("Already installed? Pair your computer →")
                }
            }
        }
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(painterResource(R.drawable.ic_brand_mark), "Bridge", Modifier.size(32.dp), tint = MaterialTheme.colorScheme.primary)
                Text("Bridge", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(12.dp))
            Surface(shape = RoundedCornerShape(40.dp), color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.fillMaxWidth()) {
                Box(Modifier.padding(40.dp), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.LaptopMac, null, Modifier.size(88.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Meet your other half.", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
                Text("Get Bridge on your computer. Then we’ll connect the two.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Button(onClick = { openDownloadLink(context, DownloadLinks.RELEASES) }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
                Icon(Icons.Outlined.Download, null); Spacer(Modifier.width(10.dp)); Text("Download Bridge for your computer")
            }
            OutlinedButton(onClick = { if (emailForm != null) openDownloadLink(context, emailForm) else showEmail = true }, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                Icon(Icons.Outlined.Email, null); Spacer(Modifier.width(10.dp))
                Text(if (emailForm != null) "Email me the computer link" else "Send link to my email")
            }
            Text(if (emailForm != null) "Enter your email on the next page to receive one download email. Email delivery uses our external email service."
                else "Prefer to open it on your computer? Create a ready-made email in Gmail or your email app, then tap Send there.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("On GitHub, open a release’s Assets. For Mac, choose Bridge-Intel.dmg for an Intel processor or Bridge-AppleSilicon.dmg for an Apple chip (M-series). Both require macOS 13 or later on supported hardware. Check Apple menu → About This Mac. See the release requirements for Arch Linux.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
    if (showEmail) AlertDialog(
        onDismissRequest = { showEmail = false; email = "" },
        title = { Text("Send the link to yourself") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Enter the address you read on your computer. We’ll open a prewritten email; you tap Send in Gmail or your email app.")
                OutlinedTextField(value = email, onValueChange = { email = it.take(254) }, label = { Text("Your email address") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton(enabled = DownloadLinks.validEmail(email.trim()), onClick = {
            val uri = Uri.parse("mailto:${Uri.encode(email.trim())}?subject=${Uri.encode(DownloadLinks.EMAIL_SUBJECT)}&body=${Uri.encode(DownloadLinks.emailBody)}")
            val draft = Intent(Intent.ACTION_SENDTO, uri)
            val opened = runCatching { context.startActivity(Intent(draft).setPackage("com.google.android.gm")) }.isSuccess ||
                runCatching { context.startActivity(draft) }.isSuccess
            if (opened) { showEmail = false; email = "" }
            else Toast.makeText(context, "No email app found. Use Download Bridge for your computer instead.", Toast.LENGTH_LONG).show()
        }) { Text("Open email draft") } },
        dismissButton = { TextButton(onClick = { showEmail = false; email = "" }) { Text("Cancel") } }
    )
}

private fun openDownloadLink(context: Context, url: String) {
    if (runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }.isFailure)
        Toast.makeText(context, "No browser found. Open github.com/mlwn4096/Bridge/releases on your computer.", Toast.LENGTH_LONG).show()
}
