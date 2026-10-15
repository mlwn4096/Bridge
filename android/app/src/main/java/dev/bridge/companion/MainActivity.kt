package dev.bridge.companion

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import android.Manifest
import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.*
import java.io.File

class MainActivity : ComponentActivity() {
    private val directPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) BridgeService.instance?.startDirectTransfer()
        else BridgeState.state.value = BridgeState.state.value.copy(error = "Allow nearby Wi-Fi access to create a direct connection")
    }
    private fun startDirectTransfer() {
        if ((Build.VERSION.SDK_INT < 36 || Build.VERSION.SDK_INT_FULL < Build.VERSION_CODES_FULL.BAKLAVA_1)) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED) BridgeService.instance?.startDirectTransfer()
        else directPermission.launch(Manifest.permission.NEARBY_WIFI_DEVICES)
    }
    private var companionInstallCompleted by mutableStateOf(false)
    private var sharedFolderRevision by mutableIntStateOf(0)
    private val flashlightPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("findPhoneFlashlight", true).apply()
            permissionsRevision++
            toastMessage = "Flashlight enabled for Find phone"
        } else toastMessage = "Camera permission is needed to use the flashlight"
    }
    private val phoneFilesFolder = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runCatching {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                val prefs = getSharedPreferences("bridge", MODE_PRIVATE)
                val old = prefs.getString("phoneFilesTree", "")
                prefs.edit().putString("phoneFilesTree", uri.toString()).apply()
                if (!old.isNullOrEmpty() && old != uri.toString()) runCatching { contentResolver.releasePersistableUriPermission(Uri.parse(old), Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                sharedFolderRevision++
                toastMessage = "Folder shared with your paired computer"
            }.onFailure { toastMessage = "Unable to retain folder access: ${it.message}" }
        }
    }
    private val clipboardHistory = ClipboardHistory.session
    private var historyRevision by mutableIntStateOf(0)
    private var historyEnabled by mutableStateOf(false)
    private fun rememberClipboard(text: String, source: String) {
        if (historyEnabled) { clipboardHistory.record(text, source); historyRevision++ }
    }
    private var permissionsRevision by mutableIntStateOf(0)
    private var sharedText by mutableStateOf("")
    private var sharedTitle = ""
    private var sharedFiles by mutableStateOf<List<Uri>>(emptyList())
    private var shareRevision by mutableIntStateOf(0)
    private data class PendingTextSend(val text: String, val reason: String, val asLink: Boolean, val title: String, val sent: () -> Unit, val cancelled: () -> Unit)
    private var textApproval by mutableStateOf<PendingTextSend?>(null)
    private var toastMessage by mutableStateOf("")
    private var pendingCopy = false
    private var pendingAction: (() -> Unit)? = null
    private var exporting: String? = null
    private var pendingReceiveID: String? = null
    private var choosingReceiveID: String? = null
    private val receiveDestination = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val id = choosingReceiveID; choosingReceiveID = null
        if (id != null) {
            if (uri != null) {
                val service = BridgeService.instance
                if (service != null) service.acceptTransfer(id, uri) else {
                    runCatching { android.provider.DocumentsContract.deleteDocument(contentResolver, uri) }
                    BridgeState.state.value = BridgeState.state.value.copy(error = "Transfer expired. Reconnect and send again.")
                }
            }
            else BridgeService.instance?.cancelTransfer(id)
        }
    }
    private fun chooseReceiveLocation(id: String) {
        val name = BridgeService.instance?.offeredFileName(id)
        if (name == null) { BridgeState.state.value = BridgeState.state.value.copy(error = "This transfer has expired. Send it again from your computer."); return }
        if (choosingReceiveID != null) { BridgeState.state.value = BridgeState.state.value.copy(error = "Finish choosing the current save location first"); return }
        choosingReceiveID = id; receiveDestination.launch(name)
    }
    private val permissionRequest = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        permissionsRevision++
        if (localPermissionGranted()) pendingAction?.invoke()
        else BridgeState.state.value = BridgeState.state.value.copy(error = "Allow local network access to connect to your computer")
        pendingAction = null
    }
    private var scanInProgress = false
    private fun scanPairingCode() {
        if (scanInProgress) return
        scanInProgress = true
        BridgeState.state.value = BridgeState.state.value.copy(error = "")
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode ->
                scanInProgress = false
                if (!isFinishing && !isDestroyed) {
                    val value = barcode.rawValue
                    if (!value.isNullOrBlank()) pair(value)
                    else BridgeState.state.value = BridgeState.state.value.copy(error = "Could not read this QR code. Scan the pairing code shown in Bridge.")
                }
            }
            .addOnCanceledListener { scanInProgress = false }
            .addOnFailureListener {
                scanInProgress = false
                if (!isFinishing && !isDestroyed) {
                    BridgeState.state.value = BridgeState.state.value.copy(
                        error = "Could not open the Android QR scanner. Check that Google Play services is up to date and connect to the internet for its first setup, then try again. You can also paste the pairing link below."
                    )
                }
            }
    }
    private fun enqueueFiles(uris: List<Uri>): Boolean {
        if (uris.isEmpty() || SecureStore(this).load() == null) return false
        BridgeService.instance?.let { return it.sendFiles(uris) }
        val queueIntent = Intent(this, BridgeService::class.java).setAction(BridgeService.ACTION_QUEUE).putParcelableArrayListExtra("files", ArrayList(uris))
        return runCatching { ContextCompat.startForegroundService(this, queueIntent); true }.getOrElse {
            BridgeState.state.value = BridgeState.state.value.copy(error = "Could not start file queue: ${it.message}"); false
        }
    }
    private val filePicker = registerForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris -> enqueueFiles(uris) }
    private fun queueAction(id: String, command: String) {
        val service = BridgeService.instance
        if (service != null) { runCatching {
            when (command) { "pause" -> service.pauseTransfer(id); "resume" -> service.resumeTransfer(id); "cancel" -> service.cancelTransfer(id) }
        }.onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = it.message ?: "Cannot update transfer") }; return }
        val action = Intent(this, BridgeService::class.java).setAction(BridgeService.ACTION_TRANSFER).putExtra("transferID", id).putExtra("command", command)
        runCatching { ContextCompat.startForegroundService(this, action) }.onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = "Could not open transfer queue: ${it.message}") }
    }
    private var folderPreparing by mutableStateOf(false)
    private var folderJob: Job? = null
    private val folderPicker = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null && !folderPreparing) {
            folderPreparing = true
            folderJob = CoroutineScope(Dispatchers.IO).launch {
                var archive: File? = null
                var handedOff = false
                try {
                    archive = FolderArchive.create(this@MainActivity, uri, cancelled = { !isActive })
                    withContext(Dispatchers.Main) { handedOff = enqueueFiles(listOf(Uri.fromFile(archive))) }
                } catch (error: Exception) {
                    if (isActive) withContext(Dispatchers.Main) { BridgeState.state.value = BridgeState.state.value.copy(error = error.message ?: "Cannot prepare folder") }
                } finally { if (!handedOff) archive?.let(FolderArchive::remove); withContext(NonCancellable + Dispatchers.Main) { folderPreparing = false } }
            }
        }
    }
    override fun onDestroy() { folderJob?.cancel(); super.onDestroy() }
    private val exporter = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val source = exporting; exporting = null
        if (uri != null && source != null) {
            CoroutineScope(Dispatchers.IO).launch {
                runCatching { contentResolver.openOutputStream(uri)?.use { output -> (if (source.startsWith("content://")) contentResolver.openInputStream(Uri.parse(source)) else File(source).inputStream())?.use { it.copyTo(output) } ?: error("Cannot read received file") } ?: error("Cannot write selected destination") }
                    .onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = it.message ?: "Could not export file") }
            }
        }
    }
    private var appearance by mutableStateOf(BridgeAppearance.SYSTEM)
    private var amoled by mutableStateOf(false)
    override fun onCreate(savedInstanceState: Bundle?) {
        val appearancePrefs = getSharedPreferences("bridge", MODE_PRIVATE)
        companionInstallCompleted = appearancePrefs.getBoolean(DownloadLinks.COMPLETED_KEY, false) || SecureStore(this).load() != null
        appearance = BridgeAppearance.stored(appearancePrefs.getString("appearance", null))
        amoled = appearancePrefs.getBoolean("amoled", false)
        historyEnabled = appearancePrefs.getBoolean("clipboardHistory", false)
        super.onCreate(savedInstanceState); choosingReceiveID = savedInstanceState?.getString("choosingReceiveID"); exporting = savedInstanceState?.getString("exporting"); enableEdgeToEdge(); handleIntent(intent)
        setContent {
            val dark = appearance.isDark(isSystemInDarkTheme())
            SideEffect {
                enableEdgeToEdge(statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT) { dark },
                    navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT) { dark })
            }
            BridgeTheme(dark, amoled) { BridgeUI(permissionsRevision) }
        }
    }
    override fun onResume() {
        super.onResume(); permissionsRevision++
        pendingReceiveID?.let { id -> pendingReceiveID = null; chooseReceiveLocation(id) }
        if (SecureStore(this).load() != null && BridgeService.instance == null && localPermissionGranted() &&
            getSharedPreferences("bridge", MODE_PRIVATE).getBoolean("enabled", false)) startServiceAction(BridgeService.ACTION_START)
    }
    override fun onPause() {
        // Approval is bound to this visible interaction, never to a later session.
        val pending = textApproval; textApproval = null; pending?.cancelled?.invoke()
        super.onPause()
    }
    override fun onSaveInstanceState(outState: Bundle) { outState.putString("choosingReceiveID", choosingReceiveID); outState.putString("exporting", exporting); super.onSaveInstanceState(outState) }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent) }
    override fun onWindowFocusChanged(hasFocus: Boolean) { super.onWindowFocusChanged(hasFocus); if (hasFocus && pendingCopy) { pendingCopy = false; copyReceived() } }
    @Suppress("DEPRECATION") private fun handleIntent(intent: Intent) {
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val previous = textApproval; textApproval = null; previous?.cancelled?.invoke()
        }
        if (intent.getBooleanExtra("copyReceived", false)) pendingCopy = true
        intent.getStringExtra("receiveTransferID")?.let { id -> pendingReceiveID = id; intent.removeExtra("receiveTransferID") }
        sharedTitle = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString() ?: intent.getCharSequenceExtra(Intent.EXTRA_TITLE)?.toString().orEmpty()
        if (intent.action == Intent.ACTION_SEND) {
            sharedFiles = listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            sharedText = if (sharedFiles.isEmpty()) intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty() else ""
        } else if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            sharedText = ""
            sharedFiles = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty().distinct()
        }
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            // Some sharing apps grant streams through ClipData instead of EXTRA_STREAM.
            if (sharedFiles.isEmpty()) {
                val clips = intent.clipData
                val files = (0 until (clips?.itemCount ?: 0)).mapNotNull { clips?.getItemAt(it)?.uri }
                    .filter { it.scheme == "content" || it.scheme == "file" }.distinct()
                if (files.isNotEmpty()) { sharedFiles = files; sharedText = "" }
            }
            shareRevision++
        }
    }
    private fun clearSharedContent() {
        sharedText = ""; sharedTitle = ""; sharedFiles = emptyList(); intent.action = null
    }
    private fun requestTextSend(text: String, asLink: Boolean = false, title: String = "", sent: () -> Unit = {}, cancelled: () -> Unit = {}): Boolean {
        if (textApproval != null) return false
        val service = BridgeService.instance ?: return false
        val reason = ClipboardProtection.reason(text)
        if (reason != null) {
            textApproval = PendingTextSend(text, reason, asLink, title, sent, cancelled)
            return false
        }
        val accepted = if (asLink) service.sendLink(text, title = title) else service.sendText(text)
        if (accepted) { if (!asLink) rememberClipboard(text, "This phone"); toastMessage = "Sent to your computer"; sent() }
        return accepted
    }
    private fun sendSharedContent(): Boolean {
        if (sharedFiles.isNotEmpty()) {
            val accepted = enqueueFiles(sharedFiles)
            if (accepted) clearSharedContent()
            return accepted
        }
        if (sharedText.isEmpty()) return false
        val link = sharedText.trim()
        val webPage = validLink(link)
        return requestTextSend(if (webPage) link else sharedText, asLink = webPage, title = sharedTitle, sent = { clearSharedContent() }, cancelled = { clearSharedContent() })
    }
    private fun localPermissionGranted(): Boolean = Build.VERSION.SDK_INT < 37 || ContextCompat.checkSelfPermission(this, "android.permission.ACCESS_LOCAL_NETWORK") == PackageManager.PERMISSION_GRANTED
    private fun withConnectionPermissions(action: () -> Unit) {
        val permissions = mutableListOf<String>()
        if (!localPermissionGranted()) permissions += "android.permission.ACCESS_LOCAL_NETWORK"
        if (permissions.isEmpty()) action() else { pendingAction = action; permissionRequest.launch(permissions.toTypedArray()) }
    }
    private fun pair(url: String) {
        runCatching { Pairing.fromURL(url) }.onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = it.message ?: "Invalid code"); return }
        completeCompanionInstall()
        withConnectionPermissions { startServiceAction(BridgeService.ACTION_PAIR, url) }
    }
    private fun completeCompanionInstall() {
        getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean(DownloadLinks.COMPLETED_KEY, true).apply()
        companionInstallCompleted = true
    }
    private fun startServiceAction(action: String, url: String? = null) {
        val intent = Intent(this, BridgeService::class.java).setAction(action)
        url?.let { intent.putExtra("url", it) }
        runCatching { ContextCompat.startForegroundService(this, intent) }.onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = it.message ?: "Could not start connection") }
    }
    private fun disconnect() {
        getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("enabled", false).apply()
        stopService(Intent(this, BridgeService::class.java))
    }
    private fun unpair() {
        folderJob?.cancel()
        clipboardHistory.clear(); historyRevision++
        BridgeService.instance?.let { startService(Intent(this, BridgeService::class.java).setAction(BridgeService.ACTION_UNPAIR)) }
            ?: run {
                runCatching { OutgoingQueue(File(filesDir, "transfer-queue")).clear() }
                getSharedPreferences("bridge", MODE_PRIVATE).edit().remove("completedFileReceiptsV1").apply()
                SecureStore(this).clear(); getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("enabled", false).apply(); BridgeState.state.value = UIState() }
        permissionsRevision++
    }
    private fun copyReceived() {
        val text = BridgeState.state.value.clipboard
        if (text.isNotEmpty()) {
            getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From computer", text))
            toastMessage = "Copied to your phone"
        }
    }
    private fun clipboardToMac() {
        val clipboard = getSystemService(ClipboardManager::class.java)
        val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        if (text.isBlank()) { BridgeState.state.value = BridgeState.state.value.copy(error = "Your clipboard is empty. Copy some text first."); return }
        requestTextSend(text)
    }
    private fun notificationPermissionGranted() = androidx.core.app.NotificationManagerCompat.getEnabledListenerPackages(this).contains(packageName)
    private fun notificationSettings() { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
    private fun openFile(path: String) {
        val uri = if (path.startsWith("content://")) Uri.parse(path) else FileProvider.getUriForFile(this, "$packageName.files", File(path))
        runCatching { startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, contentResolver.getType(uri) ?: "*/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)) }
            .onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = "No installed app can open this file; use Save a copy") }
    }
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun ClipboardHistorySheet(onDismiss: () -> Unit) {
        var query by remember { mutableStateOf("") }
        var confirmClear by remember { mutableStateOf(false) }
        var clock by remember { mutableLongStateOf(System.currentTimeMillis()) }
        LaunchedEffect(Unit) { while (true) { delay(60000); clock = System.currentTimeMillis() } }
        val historySignal by clipboardHistory.revision.collectAsStateWithLifecycle()
        val entries = remember(historySignal, historyRevision, clock, query) { clipboardHistory.entries(clock).filter { it.text.contains(query, ignoreCase = true) || it.source.contains(query, ignoreCase = true) } }
        ModalBottomSheet(onDismissRequest = onDismiss) {
            Column(Modifier.fillMaxWidth().heightIn(max = 650.dp).verticalScroll(rememberScrollState()).imePadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Clipboard history", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                    TextButton(onClick = { confirmClear = true }) { Text("Clear all") }
                }
                OutlinedTextField(query, { query = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Search text or source") }, singleLine = true)
                if (entries.isEmpty()) Text("No matching text. Send or receive clipboard text while history is enabled.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                entries.forEach { entry ->
                    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("${entry.source} · ${java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(java.util.Date(entry.createdAt))}", style = MaterialTheme.typography.labelSmall)
                            var expanded by rememberSaveable(entry.id) { mutableStateOf(false) }
                            SelectionContainer { Text(entry.text, maxLines = if (expanded) Int.MAX_VALUE else 5, overflow = TextOverflow.Ellipsis) }
                            if (entry.text.length > 240 || entry.text.count { it == '\n' } >= 5) TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Show less" else "Show more") }
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                TextButton(onClick = { getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Bridge history", entry.text)); toastMessage = "Copied to your phone" }) { Text("Copy") }
                                TextButton(onClick = { clipboardHistory.togglePin(entry.id); historyRevision++ }) { Text(if (entry.pinned) "Unpin" else "Pin") }
                                TextButton(onClick = { clipboardHistory.delete(entry.id); historyRevision++ }) { Text("Delete") }
                            }
                        }
                    }
                }
                Text("Memory only. Pins last until Bridge’s process ends.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, title = { Text("Clear all clipboard history?") }, text = { Text("This also removes pinned entries.") }, confirmButton = { TextButton(onClick = { clipboardHistory.clear(); historyRevision++; confirmClear = false }) { Text("Clear all") } }, dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } })
    }
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun BridgeUI(revision: Int) {
        val ui by BridgeState.state.collectAsStateWithLifecycle()
        var transferClock by remember { mutableLongStateOf(android.os.SystemClock.elapsedRealtime()) }
        val activeTransfer = ui.transfers.any { it.status in listOf("Sending", "Receiving", "Finishing") }
        LaunchedEffect(activeTransfer) {
            if (activeTransfer) while (true) { delay(1000); transferClock = android.os.SystemClock.elapsedRealtime() }
        }
        var tab by rememberSaveable { mutableIntStateOf(0) }
        var manualURL by rememberSaveable { mutableStateOf("") }
        var text by rememberSaveable { mutableStateOf("") }
        var confirmUnpair by remember { mutableStateOf(false) }
        LaunchedEffect(ui.connected, shareRevision) {
            val isFileShare = sharedFiles.isNotEmpty()
            if (!ui.connected) {
                val pending = textApproval; textApproval = null; pending?.cancelled?.invoke()
            } else if (sendSharedContent()) tab = if (isFileShare) 1 else 0
        }
        textApproval?.let { request ->
            fun cancel() { textApproval = null; request.cancelled() }
            AlertDialog(
                onDismissRequest = { cancel() },
                icon = { Icon(Icons.Outlined.Lock, contentDescription = null) },
                title = { Text("Sensitive text detected") },
                text = { Text("${request.reason}. Send this text to your computer just this once?") },
                confirmButton = { TextButton(enabled = ui.connected, onClick = {
                    textApproval = null
                    val service = BridgeService.instance
                    val consent = ClipboardConsent(request.text)
                    val accepted = if (request.asLink) service?.sendLink(request.text, consent, request.title) else service?.sendText(request.text, consent)
                    if (accepted == true) { toastMessage = "Sent to your computer"; request.sent() }
                }) { Text("Send once") } },
                dismissButton = { TextButton(onClick = { cancel() }) { Text("Don’t send") } }
            )
        }
        var supportKind by rememberSaveable { mutableStateOf("") }
        var bugDraft by rememberSaveable(stateSaver = SupportDraftSaver) { mutableStateOf(SupportDraft()) }
        var featureDraft by rememberSaveable(stateSaver = SupportDraftSaver) { mutableStateOf(SupportDraft()) }
        if (supportKind.isNotEmpty()) BridgeSupportForm(supportKind == "bug", if (supportKind == "bug") bugDraft else featureDraft,
            onDraftChange = { if (supportKind == "bug") bugDraft = it else featureDraft = it }, onDismiss = { supportKind = "" })
        val paired = remember(revision, ui.connected, ui.macName) { SecureStore(this).load() }
        if (paired == null) {
            if (!companionInstallCompleted && !ui.pairing) {
                CompanionDownloadScreen(onContinue = { completeCompanionInstall() })
                return
            }
            PairingScreen(ui, manualURL, { manualURL = it }, onScan = {
                scanPairingCode()
            }, onPair = { pair(manualURL.trim()) }, onSupport = { supportKind = "bug" })
            return
        }
        val snackbar = remember { SnackbarHostState() }
        LaunchedEffect(toastMessage) {
            val message = toastMessage
            if (message.isNotEmpty()) { snackbar.showSnackbar(message); if (toastMessage == message) toastMessage = "" }
        }
        var settingsQuery by rememberSaveable { mutableStateOf("") }
        var showHistory by remember { mutableStateOf(false) }
        var showComposer by rememberSaveable { mutableStateOf(false) }
        var showAdvanced by rememberSaveable { mutableStateOf(false) }
        var showAppearance by rememberSaveable { mutableStateOf(false) }
        var showPrivacy by rememberSaveable { mutableStateOf(false) }
        var showApps by rememberSaveable { mutableStateOf(false) }
        var activityFilter by rememberSaveable { mutableIntStateOf(0) }
        val tabs = listOf("Send", "Activity", "Settings")
        val icons = listOf(Icons.AutoMirrored.Outlined.Send, Icons.Outlined.Folder, Icons.Outlined.Settings)
        // Shared content belongs to Activity once sent; the old four-tab layout is gone.
        LaunchedEffect(tab) { if (tab > 2) tab = 0 }
        Scaffold(
            containerColor = MaterialTheme.colorScheme.surface,
            topBar = {
                Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 24.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    BridgeMark(Modifier.size(30.dp))
                    Text("Bridge", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    val statusColor by animateColorAsState(if (ui.connected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh, tween(250), label = "Connection color")
                    Surface(color = statusColor, shape = RoundedCornerShape(50), modifier = Modifier.animateContentSize(tween(200))) {
                        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(if (ui.connected) Icons.Outlined.Wifi else Icons.Outlined.WifiOff, null, Modifier.size(16.dp))
                            Text(if (ui.connected) "Connected" else "Offline", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
            },
            snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                NavigationBar(containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp) {
                    tabs.forEachIndexed { index, label ->
                        NavigationBarItem(selected = tab == index, onClick = { tab = index }, icon = { Icon(icons[index], null) }, label = { Text(label) })
                    }
                }
            }
        ) { padding ->
            AnimatedContent(targetState = tab, modifier = Modifier.fillMaxSize(), label = "Bridge navigation",
                transitionSpec = {
                    val direction = if (targetState > initialState) 1 else -1
                    ((fadeIn(tween(190, delayMillis = 35)) + slideInHorizontally(tween(220)) { direction * it / 30 }) togetherWith
                        (fadeOut(tween(120)) + slideOutHorizontally(tween(180)) { -direction * it / 30 })).using(SizeTransform(clip = false))
                }) { activeTab ->
            val scrollState = rememberScrollState()
            Box(Modifier.fillMaxSize().padding(padding).imePadding(), contentAlignment = Alignment.TopCenter) {
            if (activeTab == 1) {
                val shown = ui.transfers.filter { transfer ->
                    val finished = transfer.status in listOf("Complete", "Cancelled", "Failed")
                    activityFilter == 0 || (activityFilter == 1 && !finished) || (activityFilter == 2 && finished)
                }.sortedBy { if (it.status in listOf("Complete", "Cancelled", "Failed")) 1 else 0 }
                LazyColumn(Modifier.widthIn(max = 640.dp).fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (ui.error.isNotEmpty()) item("error") { ErrorBanner(ui.error) }
                    if (sharedText.isNotEmpty() || sharedFiles.isNotEmpty()) item("pending-share") { PendingShare(ui) { tab = 1 } }
                    item("heading") { SectionHeading("Activity", "Files between your devices") }
                    item("filters") { FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("All", "In progress", "Finished").forEachIndexed { index, label ->
                            FilterChip(selected = activityFilter == index, onClick = { activityFilter = index }, label = { Text(label) })
                        }
                    } }
                    if (shown.isEmpty()) item("empty") {
                        EmptyState(Icons.Outlined.FolderOpen, if (ui.transfers.isEmpty()) "No files yet" else "Nothing here", if (ui.transfers.isEmpty()) "Choose files on your phone, or send them from Bridge on your computer." else "Transfers will appear here when their status matches this filter.")
                        if (ui.transfers.isEmpty()) FilledTonalButton(onClick = { tab = 0 }, modifier = Modifier.fillMaxWidth()) { Text("Send files") }
                    } else {
                        item("save-help") { Text("Downloads/FromBridge · Files over 1 GB ask where to save", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        items(shown, key = { it.id }) { transfer -> TransferCard(transfer, transferClock) }
                    }
                }
            } else {
            Column(Modifier.widthIn(max = 640.dp).fillMaxSize().verticalScroll(scrollState).padding(horizontal = 20.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                if (ui.error.isNotEmpty()) ErrorBanner(ui.error)
                if (sharedText.isNotEmpty() || sharedFiles.isNotEmpty()) PendingShare(ui) { tab = 1 }
                when (activeTab) {
                    0 -> {
                        SectionHeading("Your devices", "Send something across.")
                        MacDeviceCard(ui, paired.name) { withConnectionPermissions { startServiceAction(BridgeService.ACTION_START) } }
                        DirectTransferCard(ui, ::startDirectTransfer)
                        if (!ui.connected) InfoCard(Icons.Outlined.WifiOff, "Let’s reconnect", "Open Bridge on your computer and use the same Wi-Fi or phone hotspot. Tap the reconnect button above.")
                        Surface(onClick = { filePicker.launch("*/*") }, shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.primaryContainer, contentColor = MaterialTheme.colorScheme.onPrimaryContainer) {
                            Row(Modifier.fillMaxWidth().padding(24.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                                Icon(Icons.Outlined.UploadFile, null, Modifier.size(36.dp))
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                    Text("Send files", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                                    Text("Choose photos, videos, or documents", style = MaterialTheme.typography.bodyMedium)
                                }
                                Icon(Icons.Outlined.ChevronRight, null)
                            }
                        }
                        if (folderPreparing) {
                            LinearProgressIndicator(Modifier.fillMaxWidth())
                            TextButton(onClick = { folderJob?.cancel() }) { Text("Cancel folder preparation") }
                        } else TextButton(onClick = { folderPicker.launch(null) }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("Send a folder as ZIP") }
                        if (!ui.connected) Text("Files queue safely until your computer reconnects.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SettingsGroup("Quick send") {
                            SettingsRow(Icons.Outlined.ContentPaste, "Clipboard", if (ui.connected) "Send copied text" else "Connect to send text", enabled = ui.connected, onClick = { clipboardToMac() }) { Icon(Icons.Outlined.ChevronRight, null) }
                            GroupDivider()
                            SettingsRow(Icons.Outlined.Edit, "Text or link", "Write or paste something", enabled = ui.connected, onClick = { showComposer = true }) { Icon(Icons.Outlined.ChevronRight, null) }
                            if (historyEnabled) {
                                GroupDivider()
                                SettingsRow(Icons.Outlined.History, "Clipboard history", "This session only", onClick = { showHistory = true }) { Icon(Icons.Outlined.ChevronRight, null) }
                            }
                        }
                        if (ui.clipboard.isNotEmpty() || ui.link.isNotEmpty()) {
                            SectionHeading("From your computer", "Ready to use on your phone")
                            if (ui.clipboard.isNotEmpty()) Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                                Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                    Text("Clipboard", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                                    var expanded by remember(ui.clipboard) { mutableStateOf(false) }
                                    Text(ui.clipboard, maxLines = if (expanded) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
                                    if (ui.clipboard.length > 180 || ui.clipboard.count { it == '\n' } >= 4) TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Show less" else "Show more") }
                                    FilledTonalButton(onClick = { copyReceived() }) { Icon(Icons.Outlined.ContentCopy, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("Copy on phone") }
                                }
                            }
                            if (ui.link.isNotEmpty()) Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                                Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                    Text("Link", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                                    Text(ui.link, maxLines = 3, overflow = TextOverflow.Ellipsis)
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        FilledTonalButton(onClick = {
                                            runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(ui.link))) }.onSuccess { BridgeState.state.value = BridgeState.state.value.copy(link = "") }.onFailure { BridgeState.state.value = BridgeState.state.value.copy(error = "No app can open this link") }
                                        }) { Text("Open link") }
                                        TextButton(onClick = { BridgeState.state.value = BridgeState.state.value.copy(link = "") }) { Text("Dismiss") }
                                    }
                                }
                            }
                        }
                        if (ui.ringing) FilledTonalButton(onClick = { BridgeService.instance?.stopRing() }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.NotificationsOff, null); Spacer(Modifier.width(8.dp)); Text("Stop ringing") }
                        val currentTransfers = ui.transfers.filter { it.status !in listOf("Complete", "Cancelled", "Failed") }
                        if (currentTransfers.isNotEmpty()) {
                            SectionHeading("In progress", "${currentTransfers.size} active transfers")
                            currentTransfers.forEach { transfer -> TransferCard(transfer, transferClock) }
                        } else if (ui.transfers.isNotEmpty()) {
                            Surface(onClick = { tab = 1 }, shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                                Row(Modifier.fillMaxWidth().padding(18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    Icon(Icons.Outlined.Folder, null, tint = MaterialTheme.colorScheme.primary)
                                    Column(Modifier.weight(1f)) {
                                        Text(ui.transfers.first().name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
                                        Text("${ui.transfers.first().status} · View activity", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    Icon(Icons.Outlined.ChevronRight, null)
                                }
                            }
                        }
                        Text("You can also send to Bridge from any app’s share menu.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp))
                    }
                    2 -> {
                        SectionHeading("Settings", "Make Bridge yours")
                        val settingsGroups = mapOf(
                            "Your computer" to "${paired.name} ${ui.status} Disconnect Connect",
                            "This phone" to "${Build.MANUFACTURER} ${Build.MODEL} Android ${Build.VERSION.RELEASE} Storage available capacity remaining space",
                            "Phone files" to "Choose Change shared folder Browse download Sharing selected folder No folder shared Stop sharing folder",
                            "Appearance" to "Theme ${appearance.label} AMOLED black Pure black backgrounds in dark mode",
                            "Clipboard & privacy" to "Clipboard history Optional · memory only · 100 entries bridge clipboardHistory Session clipboard history View history Text from this session Privacy & retention Encrypted. No account or cloud relay. Clipboard history stays in memory. Unpinned text expires after 24 hours; pins and all other entries disappear when Bridge’s process ends. Suspected secrets are excluded, even when sending is approved. History clears when disabled or unpaired. Files transfer directly between your paired devices.",
                            "Notifications" to "Apps shared with computer Choose which apps can share notifications",
                            "Find phone" to "Use flashlight Flash while your computer rings this phone findPhoneFlashlight Use flashlight when finding this phone Optional camera permission is requested when you enable this.",
                            "Connection" to "Connection help Wi-Fi hotspot manual address computer IP address Port Save reconnect discovery certificate",
                            "Support" to "Report a bug Tell us what went wrong bug Suggest a feature Share an idea for Bridge feature Buy me a coffee Support independent development https://buymeacoffee.com/mlwn About the creator Made by MLWN · mlwn.in https://mlwn.in"
                        )
                        val permissionKeywords = "Permissions Notification access Share phone notifications with your computer Local network Allow Bridge to connect Bridge notifications connection transfer status restricted settings"
                        val settingsSearchIndex = settingsGroups.map { (title, words) -> "$title $words" } + listOf(permissionKeywords, "Unpair ${paired.name}")
                        OutlinedTextField(settingsQuery, { settingsQuery = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                            placeholder = { Text("Search settings") }, leadingIcon = { Icon(Icons.Outlined.Search, null) },
                            trailingIcon = { if (settingsQuery.isNotEmpty()) IconButton(onClick = { settingsQuery = "" }) { Icon(Icons.Outlined.Close, "Clear search") } })
                        if (settingsSearchIndex.none { settingsMatches(settingsQuery, it) }) Text("No settings match your search.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SearchSettingsGroup(settingsQuery, "Your computer", settingsGroups.getValue("Your computer")) {
                            SettingsRow(Icons.Outlined.LaptopMac, paired.name, ui.status)
                            FlowRow(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (ui.connected) FilledTonalButton(onClick = { disconnect() }) { Text("Disconnect") }
                                else FilledTonalButton(onClick = { withConnectionPermissions { startServiceAction(BridgeService.ACTION_START) } }) { Text("Connect") }
                            }
                        }
                        SearchSettingsGroup(settingsQuery, "This phone", settingsGroups.getValue("This phone")) {
                            SettingsRow(Icons.Outlined.PhoneAndroid, "${Build.MANUFACTURER} ${Build.MODEL}", "Android ${Build.VERSION.RELEASE}")
                            val storage = android.os.StatFs(filesDir.absolutePath)
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("${android.text.format.Formatter.formatFileSize(this@MainActivity, storage.availableBytes)} available of ${android.text.format.Formatter.formatFileSize(this@MainActivity, storage.totalBytes)}", style = MaterialTheme.typography.bodySmall)
                                LinearProgressIndicator(progress = { ((storage.totalBytes - storage.availableBytes).toFloat() / storage.totalBytes.coerceAtLeast(1)).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                            }
                        }
                        SearchSettingsGroup(settingsQuery, "Phone files", settingsGroups.getValue("Phone files")) {
                            val folderSignal = sharedFolderRevision
                            val prefs = getSharedPreferences("bridge", MODE_PRIVATE)
                            val folderUri = remember(folderSignal) { prefs.getString("phoneFilesTree", null)?.let(Uri::parse)?.takeIf { candidate -> contentResolver.persistedUriPermissions.any { it.uri == candidate && it.isReadPermission } } }
                            val folderName = remember(folderUri) { folderUri?.let { tree -> runCatching {
                                val document = android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, android.provider.DocumentsContract.getTreeDocumentId(tree))
                                contentResolver.query(document, arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
                            }.getOrNull() } }
                            SettingsRow(Icons.Outlined.Folder, if (folderUri == null) "Choose shared folder" else "Change shared folder", if (folderUri == null) "No folder shared · Choose one to browse from your computer" else "Sharing ${folderName ?: "selected folder"} · Browse and download from your computer", onClick = { phoneFilesFolder.launch(folderUri) }) { Icon(Icons.Outlined.ChevronRight, null) }
                            if (folderUri != null) TextButton(onClick = {
                                val prefs = getSharedPreferences("bridge", MODE_PRIVATE)
                                prefs.getString("phoneFilesTree", null)?.let { runCatching { contentResolver.releasePersistableUriPermission(Uri.parse(it), Intent.FLAG_GRANT_READ_URI_PERMISSION) } }
                                prefs.edit().remove("phoneFilesTree").apply()
                                sharedFolderRevision++
                                toastMessage = "Folder sharing stopped"
                            }) { Text("Stop sharing folder") }
                        }
                        SearchSettingsGroup(settingsQuery, "Appearance", settingsGroups.getValue("Appearance")) {
                            SettingsRow(Icons.Outlined.Palette, "Theme", appearance.label, onClick = { showAppearance = true }) { Icon(Icons.Outlined.ChevronRight, null) }
                            GroupDivider()
                            SettingsRow(Icons.Outlined.DarkMode, "AMOLED black", "Pure black backgrounds in dark mode") {
                                Switch(checked = amoled, onCheckedChange = {
                                    amoled = it
                                    getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("amoled", it).apply()
                                }, modifier = Modifier.semantics { contentDescription = "AMOLED black backgrounds in dark mode" })
                            }
                        }
                        SearchSettingsGroup(settingsQuery, "Clipboard & privacy", settingsGroups.getValue("Clipboard & privacy")) {
                            SettingsRow(Icons.Outlined.History, "Clipboard history", "Optional · memory only · 100 entries") {
                                Switch(checked = historyEnabled, onCheckedChange = { enabled ->
                                    historyEnabled = enabled
                                    getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("clipboardHistory", enabled).apply()
                                    if (!enabled) { clipboardHistory.clear(); historyRevision++ }
                                }, modifier = Modifier.semantics { contentDescription = "Session clipboard history" })
                            }
                            if (historyEnabled) {
                                GroupDivider()
                                SettingsRow(Icons.Outlined.ContentPaste, "View history", "Text from this session", onClick = { showHistory = true }) { Icon(Icons.Outlined.ChevronRight, null) }
                            }
                            GroupDivider()
                            SettingsRow(Icons.Outlined.Lock, "Privacy & retention", "Encrypted. No account or cloud relay.", onClick = { showPrivacy = !showPrivacy }) { Icon(if (showPrivacy) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null) }
                            if (showPrivacy) Text("Clipboard history stays in memory. Unpinned text expires after 24 hours; pins and all other entries disappear when Bridge’s process ends. Suspected secrets are excluded, even when sending is approved. History clears when disabled or unpaired. Files transfer directly between your paired devices.", Modifier.padding(horizontal = 20.dp).padding(bottom = 20.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (settingsMatches(settingsQuery, permissionKeywords)) permissionCard(revision)
                        SearchSettingsGroup(settingsQuery, "Notifications", settingsGroups.getValue("Notifications")) {
                            SettingsRow(Icons.Outlined.Apps, "Apps shared with computer", "Choose which apps can share notifications", onClick = { showApps = !showApps }) { Icon(if (showApps) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null) }
                            if ((Build.VERSION.SDK_INT >= 36 && Build.VERSION.SDK_INT_FULL >= Build.VERSION_CODES_FULL.BAKLAVA_1)) {
                                GroupDivider()
                                var liveConnection by remember { mutableStateOf(getSharedPreferences("bridge", MODE_PRIVATE).getBoolean("liveConnection", true)) }
                                SettingsRow(Icons.Outlined.Link, "Live connection", "Show connection status on supported system surfaces") {
                                    Switch(checked = liveConnection, onCheckedChange = {
                                        liveConnection = it
                                        getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("liveConnection", it).apply()
                                        BridgeService.instance?.refreshConnectionNotification()
                                    })
                                }
                            }
                            if (showApps) Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp)) { AppExclusions() }
                        }
                        val findPreferences = remember { getSharedPreferences("bridge", MODE_PRIVATE) }
                        var findFlashlight by remember(permissionsRevision) { mutableStateOf(findPreferences.getBoolean("findPhoneFlashlight", false)) }
                        SearchSettingsGroup(settingsQuery, "Find phone", settingsGroups.getValue("Find phone")) {
                            SettingsRow(Icons.Outlined.FlashlightOn, "Use flashlight", "Flash while your computer rings this phone") {
                                Switch(checked = findFlashlight, onCheckedChange = { enabled ->
                                    if (enabled && ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                                        flashlightPermission.launch(Manifest.permission.CAMERA)
                                    } else { findFlashlight = enabled; findPreferences.edit().putBoolean("findPhoneFlashlight", enabled).apply(); if (!enabled) BridgeService.instance?.stopFindFlashlight() }
                                }, modifier = Modifier.semantics { contentDescription = "Use flashlight when finding this phone" })
                            }
                            if (!findFlashlight) Text("Optional camera permission is requested when you enable this.", Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        SearchSettingsGroup(settingsQuery, "Connection", settingsGroups.getValue("Connection")) {
                            SettingsRow(Icons.Outlined.Wifi, "Connection help", "Wi-Fi, hotspot and manual address", onClick = { showAdvanced = !showAdvanced }) { Icon(if (showAdvanced) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null) }
                            if (showAdvanced) Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text("Keep both devices on the same Wi-Fi or phone hotspot. Open Bridge on your computer if it is offline.", style = MaterialTheme.typography.bodyMedium)
                                AddressOverride(paired) { permissionsRevision++ }
                            }
                        }
                        SearchSettingsGroup(settingsQuery, "Support", settingsGroups.getValue("Support")) {
                            SettingsRow(Icons.Outlined.BugReport, "Report a bug", "Tell us what went wrong", onClick = { supportKind = "bug" }) { Icon(Icons.Outlined.ChevronRight, null) }
                            GroupDivider()
                            SettingsRow(Icons.Outlined.Lightbulb, "Suggest a feature", "Share an idea for Bridge", onClick = { supportKind = "feature" }) { Icon(Icons.Outlined.ChevronRight, null) }
                            GroupDivider()
                            SettingsRow(Icons.Outlined.Coffee, "Buy me a coffee", "Support independent development", onClick = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://buymeacoffee.com/mlwn"))) }) { Icon(Icons.Outlined.OpenInNew, null) }
                            GroupDivider()
                            SettingsRow(Icons.Outlined.Person, "About the creator", "Made by MLWN · mlwn.in", onClick = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://mlwn.in"))) }) { Icon(Icons.Outlined.OpenInNew, null) }
                        }
                        if (settingsMatches(settingsQuery, "Unpair " + paired.name)) TextButton(onClick = { confirmUnpair = true }, modifier = Modifier.fillMaxWidth()) { Text("Unpair ${paired.name}", color = MaterialTheme.colorScheme.error) }
                        Text("Bridge ${remember { packageManager.getPackageInfo(packageName, 0).versionName ?: "" }} · Made for your devices", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.align(Alignment.CenterHorizontally))
                    }
                }
            }
            }
            }
            }
        }
        if (showAppearance) AlertDialog(onDismissRequest = { showAppearance = false },
            title = { Text("Choose theme") },
            text = { Column {
                BridgeAppearance.entries.forEach { choice ->
                    SettingsRow(if (choice == BridgeAppearance.SYSTEM) Icons.Outlined.Settings else if (choice == BridgeAppearance.DARK) Icons.Outlined.DarkMode else Icons.Outlined.LightMode,
                        choice.label, "", onClick = {
                            appearance = choice
                            getSharedPreferences("bridge", MODE_PRIVATE).edit().putString("appearance", choice.name).apply()
                        }) { RadioButton(selected = appearance == choice, onClick = null) }
                }
            } }, confirmButton = { TextButton(onClick = { showAppearance = false }) { Text("Done") } })
        if (showHistory && historyEnabled) ClipboardHistorySheet(onDismiss = { showHistory = false })
        if (showComposer) ModalBottomSheet(onDismissRequest = { showComposer = false }) {
            Column(Modifier.fillMaxWidth().imePadding().padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Send text or a link", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                Text("It will appear on ${paired.name}.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(value = text, onValueChange = { text = it }, placeholder = { Text("Write or paste here…") }, modifier = Modifier.fillMaxWidth(), minLines = 3, maxLines = 6, shape = MaterialTheme.shapes.medium)
                if (ui.error.isNotEmpty()) ErrorBanner(ui.error)
                Button(modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), enabled = ui.connected && text.isNotBlank(), onClick = {
                    val draft = text
                    val outgoing = if (validLink(draft.trim())) draft.trim() else draft
                    if (ClipboardProtection.reason(outgoing) != null) showComposer = false
                    requestTextSend(outgoing, asLink = validLink(outgoing), sent = { if (text == draft) text = ""; showComposer = false })
                }) { Icon(Icons.AutoMirrored.Outlined.Send, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(if (validLink(text.trim())) "Send link to computer" else "Send text to computer") }
                if (!ui.connected) Text("Reconnect to your computer to send.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (confirmUnpair) AlertDialog(onDismissRequest = { confirmUnpair = false }, title = { Text("Unpair your computer?") }, text = { Text("You’ll need to scan its code again to reconnect.") },
            confirmButton = { TextButton(onClick = { confirmUnpair = false; unpair() }) { Text("Unpair") } }, dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } })
    }
    @Composable private fun PendingShare(ui: UIState, onSent: () -> Unit) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.secondaryContainer) {
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Ready to send", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(if (sharedFiles.isNotEmpty()) "${sharedFiles.size} files selected" else sharedText.take(160), maxLines = 3, overflow = TextOverflow.Ellipsis)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(enabled = ui.connected || sharedFiles.isNotEmpty(), onClick = { if (sendSharedContent()) onSent() }) { Text("Send to computer") }
                    TextButton(onClick = { clearSharedContent() }) { Text("Cancel") }
                }
            }
        }
    }
    @Composable private fun TransferCard(transfer: Transfer, transferClock: Long) {
                            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                        Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = RoundedCornerShape(12.dp)) { Icon(if (transfer.incoming) Icons.Outlined.Download else Icons.Outlined.Upload, null, Modifier.padding(10.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer) }
                                        Column(Modifier.weight(1f)) {
                                            Text(transfer.name, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                            Text(if (transfer.incoming) "From your computer" else "To your computer", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                    Text("${android.text.format.Formatter.formatFileSize(this@MainActivity, transfer.size)} · ${transfer.status}" + (if (transfer.bytesPerSecond > 0 && (transfer.lastProgressElapsed == 0L || transferClock - transfer.lastProgressElapsed <= 5000 || transfer.status == "Complete")) " · %.1f MB/s".format(transfer.bytesPerSecond / 1_000_000) else ""), color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (transfer.status in listOf("Sending", "Receiving", "Finishing", "Verifying")) LinearProgressIndicator(progress = { transfer.progress }, modifier = Modifier.fillMaxWidth())
                                    if (transfer.status in listOf("Sending", "Receiving", "Finishing")) {
                                        val stalled = transfer.lastProgressElapsed > 0 && transferClock - transfer.lastProgressElapsed > 5000
                                        val remaining = if (stalled) null else transferEta(transfer.size, transfer.progress, transfer.bytesPerSecond)
                                        Text("${(transfer.progress.coerceIn(0f, 1f) * 100).toInt()}%" + (if (stalled) " · Waiting for data…" else remaining?.let { " · $it" } ?: " · Estimating time…"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    if (transfer.failureReason.isNotEmpty() && transfer.status in listOf("Paused", "Retrying")) Text(transfer.failureReason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    transfer.timings.summary()?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                    if (transfer.path != null || transfer.status !in listOf("Complete", "Cancelled", "Failed")) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                        if (!transfer.incoming && transfer.status !in listOf("Complete", "Cancelled", "Failed", "Preparing")) {
                                            if (transfer.status == "Paused") FilledTonalButton(onClick = { queueAction(transfer.id, "resume") }) { Text("Retry") }
                                            else TextButton(onClick = { queueAction(transfer.id, "pause") }) { Text("Pause") }
                                        }
                                        if (transfer.status == "Paused") Text("Restarts from the beginning", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        if (transfer.status == "Choose save location") Button(onClick = { chooseReceiveLocation(transfer.id) }) { Text("Choose save location") }
                                        if (transfer.status !in listOf("Complete", "Cancelled", "Failed")) TextButton(onClick = { queueAction(transfer.id, "cancel") }) { Text("Cancel") }
                                        transfer.path?.let { path ->
                                            OutlinedButton(onClick = { openFile(path) }) { Text("Open") }
                                            TextButton(onClick = { exporting = path; exporter.launch(transfer.name) }) { Text("Save a copy") }
                                        }
                                    }
                                }
                            }
    }
    @Composable private fun ErrorBanner(message: String) {
        Surface(color = MaterialTheme.colorScheme.errorContainer, shape = MaterialTheme.shapes.medium) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp, bottom = 8.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(message, Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodyMedium)
                IconButton(onClick = { BridgeState.state.value = BridgeState.state.value.copy(error = "") }) { Icon(Icons.Outlined.Close, "Dismiss error") }
            }
        }
    }
    @Composable private fun BridgeMark(modifier: Modifier = Modifier) {
        Icon(androidx.compose.ui.res.painterResource(R.drawable.ic_brand_mark), contentDescription = "Bridge", modifier = modifier, tint = MaterialTheme.colorScheme.primary)
    }

    @Composable private fun PairingScreen(ui: UIState, manualURL: String, onURL: (String) -> Unit, onScan: () -> Unit, onPair: () -> Unit, onSupport: () -> Unit) {
        var showManual by rememberSaveable { mutableStateOf(false) }
        Scaffold(containerColor = MaterialTheme.colorScheme.surface) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    BridgeMark(Modifier.size(32.dp))
                    Text("Bridge", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.height(12.dp))
                Surface(shape = RoundedCornerShape(40.dp), color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(vertical = 36.dp, horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceEvenly) {
                        Icon(Icons.Outlined.PhoneAndroid, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
                        Icon(Icons.Outlined.SyncAlt, null, Modifier.size(28.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
                        Icon(Icons.Outlined.LaptopMac, null, Modifier.size(60.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("A little closer.", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
                    Text("Your phone and computer, connected privately. Files, clipboard and notifications in one place.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    PairingStep("1", "Open Bridge on your computer", "Open its pairing screen to see the QR code.")
                    PairingStep("2", "Scan and approve", "Scan below, then approve your phone on the computer.")
                }
                if (ui.error.isNotEmpty()) ErrorBanner(ui.error)
                if (ui.pairing) Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.large) {
                    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        Text("Approve on your computer", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(ui.status, style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = { disconnect() }) { Text("Cancel pairing") }
                    }
                } else {
                    Button(onClick = onScan, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Icon(Icons.Outlined.QrCodeScanner, null); Spacer(Modifier.width(10.dp)); Text("Scan QR code", style = MaterialTheme.typography.titleMedium) }
                    TextButton(onClick = { showManual = !showManual }, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text(if (showManual) "Hide pairing link" else "Have a pairing link?") }
                    if (showManual) {
                        OutlinedTextField(value = manualURL, onValueChange = onURL, modifier = Modifier.fillMaxWidth(), label = { Text("Pairing link") }, placeholder = { Text("bridge://pair?…") }, maxLines = 4, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                        OutlinedButton(enabled = manualURL.isNotBlank(), onClick = onPair, modifier = Modifier.fillMaxWidth()) { Text("Connect to computer") }
                    }
                }
                TextButton(onClick = onSupport, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text("Need help? Report a setup problem") }
                Text("Use the same Wi-Fi or phone hotspot. Your connection is encrypted, with no account needed.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
    }
    @Composable private fun PairingStep(number: String, title: String, detail: String) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.primaryContainer) { Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) { Text(number, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer) } }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    @Composable private fun SectionHeading(title: String, subtitle: String) {
        Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, modifier = Modifier.semantics { heading() }, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Medium)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    @Composable private fun InfoCard(icon: ImageVector, title: String, detail: String) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Row(Modifier.fillMaxWidth().padding(20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    @Composable private fun EmptyState(icon: ImageVector, title: String, detail: String) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.secondaryContainer) { Icon(icon, null, Modifier.padding(24.dp).size(40.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer) }
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(detail, style = MaterialTheme.typography.bodyMedium, textAlign = androidx.compose.ui.text.style.TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    private fun settingsMatches(query: String, text: String): Boolean = query.trim().split(Regex("\\s+")).all { text.contains(it, ignoreCase = true) }
    @Composable private fun SearchSettingsGroup(query: String, title: String, keywords: String, content: @Composable ColumnScope.() -> Unit) {
        if (settingsMatches(query, "$title $keywords")) SettingsGroup(title, content)
    }
    @Composable private fun permissionCard(revision: Int) {
        val notificationsAllowed = remember(revision) { notificationPermissionGranted() }
        SettingsGroup("Permissions") {
            SettingsRow(Icons.Outlined.NotificationsActive, "Notification access", if (notificationsAllowed) "Enabled · tap to manage" else "Share phone notifications with your computer", onClick = { notificationSettings() }) { Icon(Icons.Outlined.ChevronRight, null) }
            if (!localPermissionGranted()) {
                GroupDivider()
                SettingsRow(Icons.Outlined.Wifi, "Local network", "Allow Bridge to connect to your computer", onClick = { withConnectionPermissions { permissionsRevision++ } }) { Icon(Icons.Outlined.ChevronRight, null) }
            }
            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                GroupDivider()
                SettingsRow(Icons.Outlined.Notifications, "Bridge notifications", "Show connection and transfer status", onClick = { permissionRequest.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS)) }) { Icon(Icons.Outlined.ChevronRight, null) }
            }
            if (Build.VERSION.SDK_INT < 31) Text("On Android 10–11, notifications can be viewed and dismissed here. Use your phone for notification actions and replies.", Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!notificationsAllowed && Build.VERSION.SDK_INT >= 33) Text("If Android blocks access: App info → menu → Allow restricted settings.", Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    @Composable private fun AppExclusions() {
        val prefs = remember { getSharedPreferences("bridge", MODE_PRIVATE) }
        var excluded by remember { mutableStateOf(prefs.getStringSet("excludedApps", emptySet()).orEmpty().toSet()) }
        val apps = prefs.getStringSet("observedApps", emptySet()).orEmpty().sorted()
        val appLabels = remember(apps) { apps.associateWith { packageName -> runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString() }.getOrDefault(packageName) } }
        if (apps.isEmpty()) Text("Apps appear here after they post a notification.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        apps.forEach { app ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(appLabels[app] ?: app, style = MaterialTheme.typography.bodyLarge)
                    Text(app, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Switch(modifier = Modifier.semantics { contentDescription = "Share notifications from ${appLabels[app] ?: app}" }, checked = app !in excluded, onCheckedChange = { enabled ->
                    excluded = if (enabled) excluded - app else excluded + app
                    prefs.edit().putStringSet("excludedApps", excluded).apply()
                    BridgeService.instance?.refreshMedia()
                    PhoneNotificationListener.instance?.publishCurrent()
                })
            }
        }
    }
    @Composable private fun AddressOverride(paired: Pairing, onSave: () -> Unit) {
        var host by remember(paired.host) { mutableStateOf(paired.host) }
        var port by remember(paired.port) { mutableStateOf(paired.port.toString()) }
        Text("Manual computer address", style = MaterialTheme.typography.titleMedium)
        Text("Use the IP and port shown by your computer when discovery is unavailable. The computer’s certificate is still verified.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(host, { host = it }, label = { Text("computer IP address") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(port, { port = it }, label = { Text("Port") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = {
            val number = port.toIntOrNull()
            if (host.matches(Regex("[A-Za-z0-9.:%_-]{1,253}")) && number != null && number in 1..65535) {
                disconnect(); SecureStore(this@MainActivity).save(paired.copy(host = host, port = number)); onSave()
                withConnectionPermissions { startServiceAction(BridgeService.ACTION_START) }
            } else BridgeState.state.value = BridgeState.state.value.copy(error = "Enter a valid address and port")
        }) { Text("Save and reconnect") }
    }
}
