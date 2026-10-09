package dev.bridge.companion

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BugReport
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType

data class SupportDraft(val name: String = "", val email: String = "", val description: String = "", val extra: String = "", val images: List<String> = emptyList())
val SupportDraftSaver = listSaver<SupportDraft, String>(
    save = { listOf(it.name, it.email, it.description, it.extra) + it.images },
    restore = { SupportDraft(it[0], it[1], it[2], it[3], it.drop(4)) })

@Composable fun BridgeSupportForm(bug: Boolean, draft: SupportDraft, onDraftChange: (SupportDraft) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val name = draft.name
    val email = draft.email
    val description = draft.description
    val extra = draft.extra
    val images = draft.images.map(Uri::parse)
    var error by remember { mutableStateOf("") }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { selected ->
        selected.forEach { uri -> runCatching { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } }
        onDraftChange(draft.copy(images = (draft.images + selected.map(Uri::toString)).distinct().take(5)))
    }
    val valid = name.isNotBlank() && android.util.Patterns.EMAIL_ADDRESS.matcher(email.trim()).matches() && description.isNotBlank()
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth().fillMaxHeight(0.95f), shape = MaterialTheme.shapes.large) {
            Column(Modifier.imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Icon(if (bug) Icons.Outlined.BugReport else Icons.Outlined.Lightbulb, null, tint = if (bug) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                    TextButton(onClick = onDismiss) { Text("Close") }
                }
                Text(if (bug) "Report a bug" else "Suggest a feature", style = MaterialTheme.typography.headlineMedium)
                Text(if (bug) "Describe what happened and how we can reproduce it." else "Tell us what you’d like Bridge to do and why it would help.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(name, { onDraftChange(draft.copy(name = it)) }, label = { Text("Full name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(email, { onDraftChange(draft.copy(email = it)) }, label = { Text("Email address") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(description, { onDraftChange(draft.copy(description = it)) }, label = { Text("Description") }, minLines = 5, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(extra, { onDraftChange(draft.copy(extra = it)) }, label = { Text(if (bug) "Steps to reproduce (optional)" else "How would you use it? (optional)") }, minLines = 2, modifier = Modifier.fillMaxWidth())
                TextButton(onClick = { picker.launch(arrayOf("image/*")) }) { Text("Add images (optional) · ${images.size}/5") }
                images.forEachIndexed { index, uri ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        val filename = remember(uri) { runCatching { context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null } }.getOrNull() }
                        Text(filename ?: "Image ${index + 1}", modifier = Modifier.weight(1f), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        TextButton(onClick = { onDraftChange(draft.copy(images = draft.images.filterNot { it == uri.toString() })) }) { Text("Remove") }
                    }
                }
                Text("Full name, a valid email address and a description are required. Your draft stays here when you close this form.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("Review screenshots for personal information. Review your draft and send it from your mail app.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (error.isNotBlank()) Text(error, color = MaterialTheme.colorScheme.error)
                Button(enabled = valid, modifier = Modifier.fillMaxWidth(), onClick = {
                    val title = if (bug) "Bridge bug report" else "Bridge feature suggestion"
                    val text = "$title\nFull name: $name\nEmail: $email\nPlatform: Android\n\nDescription:\n$description\n\n${if (bug) "Steps to reproduce" else "Use case"}:\n$extra"
                    val intent = Intent(if (images.isEmpty()) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
                        type = if (images.isEmpty()) "text/plain" else "image/*"
                        putExtra(Intent.EXTRA_EMAIL, arrayOf(String(android.util.Base64.decode("bWVsd2luc2FudGhvc2hAb3V0bG9vay5jb20=", android.util.Base64.NO_WRAP), Charsets.UTF_8)))
                        putExtra(Intent.EXTRA_SUBJECT, title); putExtra(Intent.EXTRA_TEXT, text)
                        if (images.isNotEmpty()) {
                            putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(images))
                            clipData = ClipData.newUri(context.contentResolver, "Support images", images.first()).apply { images.drop(1).forEach { addItem(ClipData.Item(it)) } }
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                    }
                    runCatching {
                        val mailApps = context.packageManager.queryIntentActivities(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:")), android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
                            .map { it.activityInfo.packageName }.distinct()
                        check(mailApps.isNotEmpty()) { "No mail app" }
                        val choices = mailApps.map { Intent(intent).setPackage(it) }
                        val chooser = Intent.createChooser(choices.first(), "Send to Bridge support")
                        if (choices.size > 1) chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, choices.drop(1).toTypedArray())
                        context.startActivity(chooser)
                    }.onFailure { error = "No app available to send the draft. Install or set up a mail app." }
                }) { Text("Continue in Mail") }
            }
        }
    }
}
