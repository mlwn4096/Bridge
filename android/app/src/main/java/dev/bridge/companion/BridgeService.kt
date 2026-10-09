package dev.bridge.companion

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.*
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import org.json.JSONObject
import java.io.*
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.*

class BridgeService : Service() {
    companion object {
        const val CHANNEL = "connection"
        const val ACTION_START = "start"
        const val ACTION_QUEUE = "queue"
        const val ACTION_TRANSFER = "transfer"
        const val ACTION_PAIR = "pair"
        const val ACTION_STOP = "stop"
        const val ACTION_LIVE_DISMISS = "liveDismiss"
        const val ACTION_UNPAIR = "unpair"
        @Volatile var instance: BridgeService? = null
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var secure: SecureStore
    private var fileQueue: OutgoingQueue? = null
    private val receipts by lazy { TransferReceipts(getSharedPreferences("bridge", MODE_PRIVATE)) }
    @Volatile private var pairing: Pairing? = null
    @Volatile private var socket: SSLSocket? = null
    @Volatile private var authenticated = false
    @Volatile private var liveDismissed = false
    @Volatile private var supportsBinary = false
    @Volatile private var receiverProgress = false
    @Volatile private var supportsTransferFailure = false
    @Volatile var notificationRepliesSupported = false
        private set
    private var connectionJob: Job? = null
    private var recoveryJob: Job? = null
    private var heartbeatJob: Job? = null
    @Volatile private var usingUSB = false
    private val sendLock = Any()
    private data class QueuedMessage(val message: Message, val connection: SSLSocket)
    private val sendQueue = Channel<QueuedMessage>(128)
    @Volatile private var lastSeen = SystemClock.elapsedRealtime()
    private val seen = LinkedHashSet<String>()
    private val offers = ConcurrentHashMap<String, JSONObject>()
    private val incomingLock = Any()
    private val incoming = ConcurrentHashMap<String, Incoming>()
    private val outgoing = ConcurrentHashMap<String, Outgoing>()
    private val preparing = ConcurrentHashMap.newKeySet<String>()
    private val outgoingLock = Any()
    private val suppressedQueueIDs = ConcurrentHashMap.newKeySet<String>()
    private val destinations = ConcurrentHashMap<String, Pair<String, Int>>()
    private var discovery: NsdManager.DiscoveryListener? = null
    private var ringtone: Ringtone? = null
    private var findTorchActive = false
    private val torch by lazy { PhoneTorch(this) }
    private val handler = Handler(Looper.getMainLooper())
    private val ringTimeout = Runnable { stopRing() }
    private val media by lazy { MediaRemote(this) { send(it); Unit } }
    @Volatile var mirrorEnabled = true
    @Volatile var previewsEnabled = false
    private data class Incoming(val uri: Uri, val mediaStore: Boolean, val output: OutputStream, val size: Long, val hash: String, val binary: Boolean,
                                val started: Long = SystemClock.elapsedRealtime(), var lastUI: Long = 0, var lastReport: Long = 0,
                                val digest: MessageDigest = MessageDigest.getInstance("SHA-256"), var bytes: Long = 0, var sequence: Long = 0)
    private data class Outgoing(val file: File, val size: Long, val binary: Boolean, var job: Job? = null, var estimator: TransferRateEstimator? = null)
    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent ?: return
            if (intent.action == PowerManager.ACTION_POWER_SAVE_MODE_CHANGED) { sendBattery(); return }
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
            if (level >= 0 && scale > 0) send(Message("battery", payload("level" to level * 100 / scale,
                "charging" to (intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0),
                "powerSave" to getSystemService(PowerManager::class.java).isPowerSaveMode)))
        }
    }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { if (authenticated && !usingUSB) { runCatching { socket?.close() } } }
        override fun onLost(network: Network) { if (!usingUSB) runCatching { socket?.close() } }
    }
    override fun onCreate() {
        super.onCreate(); secure = SecureStore(this); pairing = secure.load(); instance = this
        try {
            fileQueue = OutgoingQueue(File(filesDir, "transfer-queue"))
            fileQueue?.all()?.filter { it.peer != pairing?.let(::queuePeer) }?.forEach { fileQueue?.remove(it.id) }
            restoreQueueUI()
        } catch (error: Exception) { showError("Transfer queue needs attention: ${error.message}") }
        scope.launch {
            for (queued in sendQueue) {
                if (authenticated && socket === queued.connection) {
                    runCatching { write(queued.message, queued.connection) }
                        .onFailure { runCatching { queued.connection.close() } }
                }
            }
        }
        scope.launch {
            var lastUpdate = 0L
            BridgeState.state.map { ui ->
                val transfer = ui.transfers.firstOrNull { it.status in setOf("Preparing", "Sending", "Receiving", "Finishing", "Verifying") }
                Triple(ui.connected, ui.macName, transfer?.let { "${it.id}:${it.status}:${(it.progress * 100).toInt()}" })
            }.distinctUntilChanged().collect { live ->
                if (live.first && authenticated && !liveDismissed) {
                    val now = SystemClock.elapsedRealtime()
                    if (live.third == null || now - lastUpdate >= 500) {
                        lastUpdate = now
                        getSystemService(NotificationManager::class.java).notify(1, connectionNotification("Connected to ${live.second}"))
                    }
                }
            }
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Bridge connection status", NotificationManager.IMPORTANCE_LOW).apply {
            setSound(null, null); enableVibration(false); setShowBadge(false)
            description = "Quiet status-bar indicator while Bridge connects to your Mac."
        })
        manager.createNotificationChannel(NotificationChannel("handoff", "Links from your Mac", NotificationManager.IMPORTANCE_DEFAULT))
        manager.createNotificationChannel(NotificationChannel("files", "File transfers", NotificationManager.IMPORTANCE_DEFAULT))
        recoveryJob = scope.launch {
            // Preparation copies belong to a single live session. Remove any
            // that survived a process kill before accepting new file work.
            cacheDir.listFiles()?.filter { it.name.matches(Regex("[0-9a-fA-F-]{36}\\.outgoing")) }
                ?.forEach { it.delete() }
            cacheDir.listFiles()?.filter { it.isDirectory && it.name.matches(Regex("bridge-folder-[0-9a-fA-F-]{36}")) && System.currentTimeMillis() - it.lastModified() > 86_400_000L }?.forEach { it.deleteRecursively() }
            cleanupPendingDownloads(); cleanupPendingDocuments()
        }
        registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED).apply {
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        })
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback)
    }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_LIVE_DISMISS -> { liveDismissed = true; return START_STICKY }
            ACTION_STOP -> { getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("enabled", false).apply(); stopSelf(); return START_NOT_STICKY }
            ACTION_UNPAIR -> { clearPairing(notify = true); handler.postDelayed({ stopSelf() }, 1000); return START_NOT_STICKY }
            ACTION_PAIR -> {
                // Never replace a working trusted Mac merely because another app
                // handed us a pairing URI. Unpair explicitly before enrolling again.
                if (secure.load() != null) {
                    showError("Unpair your current Mac before pairing another device")
                    return START_STICKY
                }
                try { pairing = Pairing.fromURL(intent.getStringExtra("url").orEmpty()) }
                catch (error: Exception) { showError(error.message ?: "Invalid pairing link"); stopSelf(); return START_NOT_STICKY }
            }
        }
        if (pairing == null) { stopSelf(); return START_NOT_STICKY }
        try { ServiceCompat.startForeground(this, 1, connectionNotification("Connecting…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) }
        catch (error: Exception) { showError("Connection permission needed: ${error.message}"); stopSelf(); return START_NOT_STICKY }
        if (intent?.action == ACTION_TRANSFER) {
            val id = intent.getStringExtra("transferID").orEmpty()
            if (runCatching { UUID.fromString(id) }.isSuccess) runCatching {
                when (intent.getStringExtra("command")) {
                    "pause" -> pauseTransfer(id)
                    "resume" -> resumeTransfer(id)
                    "cancel" -> cancelTransfer(id)
                }
            }.onFailure { showError("Could not update transfer: ${it.message}") }
            if (connectionJob?.isActive == true) return START_STICKY
            if (intent.getStringExtra("command") != "resume") { stopSelf(); return START_NOT_STICKY }
        }
        getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("enabled", true).apply()
        if (intent?.action == ACTION_QUEUE) {
            @Suppress("DEPRECATION") val uris = intent.getParcelableArrayListExtra<Uri>("files").orEmpty()
            if (!sendFiles(uris)) uris.forEach { cleanupFolderStage(it) }
            if (connectionJob?.isActive == true) return START_STICKY
        }
        val previous = connectionJob
        previous?.cancel(); runCatching { socket?.close() }
        connectionJob = scope.launch { previous?.join(); connectionLoop() }
        startDiscovery()
        return START_STICKY
    }
    private fun tlsContext(peer: Pairing): SSLContext {
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) = throw java.security.cert.CertificateException("Client certificates unsupported")
            override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) {
                val certificate = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("No server certificate")
                certificate.checkValidity()
                if (!MessageDigest.isEqual(sha256(certificate.encoded).toByteArray(), peer.fingerprint.toByteArray()))
                    throw java.security.cert.CertificateException("Mac identity does not match. Pair again.")
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        return tls
    }
    private fun connectTLS(tls: SSLContext, host: String, port: Int, timeout: Int): SSLSocket {
        val connection = tls.socketFactory.createSocket() as SSLSocket
        try {
            connection.enabledProtocols = connection.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
            connection.receiveBufferSize = 1_048_576; connection.sendBufferSize = 1_048_576
            connection.tcpNoDelay = true
            connection.soTimeout = timeout
            connection.connect(InetSocketAddress(host, port), timeout)
            connection.startHandshake()
            return connection
        } catch (error: Exception) { runCatching { connection.close() }; throw error }
    }
    private fun transfersIdle(): Boolean = incoming.isEmpty() && outgoing.isEmpty() && preparing.isEmpty() && offers.isEmpty()
    private suspend fun connectionLoop() {
        var delayMillis = 1000L
        while (currentCoroutineContext().isActive) {
            val peer = pairing ?: break
            startDiscovery()
            BridgeState.state.update { it.copy(connected = false, pairing = peer.token.isNotEmpty(), macName = peer.name,
                status = if (peer.token.isNotEmpty()) "Connecting to your Mac…" else "Reconnecting…", error = "") }
            var receiver: OrderedReceivePipeline? = null
            try {
                val destination = destinations[peer.service] ?: (peer.host to peer.port)
                val tls = tlsContext(peer)
                // Probe the USB reverse port first; certificate pinning also applies here.
                val wired = runCatching { connectTLS(tls, "127.0.0.1", 38473, 1500) }.getOrNull()
                usingUSB = wired != null
                val connection = wired ?: connectTLS(tls, destination.first, destination.second, 7000)
                socket = connection; connection.soTimeout = 90_000
                authenticated = false; supportsBinary = false; receiverProgress = false; supportsTransferFailure = false; notificationRepliesSupported = false; seen.clear()
                if (peer.token.isNotEmpty()) {
                    write(Message("pairRequest", payload("token" to peer.token, "deviceID" to peer.deviceID,
                        "credential" to peer.credential, "name" to Build.MODEL, "transport" to if (usingUSB) "usb" else "wifi", "capabilities" to org.json.JSONArray(listOf("binaryFileV1", "receiverProgressV1", "fileFailureV1", "notificationReplyV1")))))
                    BridgeState.state.update { it.copy(status = "Approve pairing on your Mac") }
                } else write(Message("auth", payload("deviceID" to peer.deviceID, "credential" to peer.credential, "transport" to if (usingUSB) "usb" else "wifi", "capabilities" to org.json.JSONArray(listOf("binaryFileV1", "receiverProgressV1", "fileFailureV1", "notificationReplyV1")))))
                receiver = OrderedReceivePipeline(scope, consume = { receive(it) }, failed = {
                    if (socket === connection) runCatching { connection.close() }
                })
                val input = connection.inputStream.buffered(BINARY_CHUNK_SIZE)
                while (currentCoroutineContext().isActive) {
                    val message = Message.read(input) ?: break
                    lastSeen = SystemClock.elapsedRealtime()
                    if (!authenticated) {
                        require(message.type == "authAccepted" || message.type == "pairAccepted") {
                            message.payload.optString("message", "Mac rejected the connection. Unpair and scan a fresh code.")
                        }
                        require((peer.token.isEmpty() && message.type == "authAccepted") || (peer.token.isNotEmpty() && message.type == "pairAccepted"))
                        supportsBinary = message.payload.optJSONArray("capabilities")?.let { array -> (0 until array.length()).any { array.optString(it) == "binaryFileV1" } } ?: false
                        receiverProgress = message.payload.optJSONArray("capabilities")?.let { array -> (0 until array.length()).any { array.optString(it) == "receiverProgressV1" } } ?: false
                        supportsTransferFailure = message.payload.optJSONArray("capabilities")?.let { array -> (0 until array.length()).any { array.optString(it) == "fileFailureV1" } } ?: false
                        notificationRepliesSupported = message.payload.optJSONArray("capabilities")?.let { array -> (0 until array.length()).any { array.optString(it) == "notificationReplyV1" } } ?: false
                        val stored = peer.copy(token = "", host = destination.first, port = destination.second)
                        synchronized(outgoingLock) {
                            check(pairing?.deviceID == peer.deviceID && pairing?.credential == peer.credential && socket === connection && connectionJob?.isActive == true) { "Pairing revoked or connection replaced" }
                            secure.save(stored); pairing = stored; authenticated = true
                        }
                        delayMillis = 1000
                        getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("enabled", true).apply()
                        BridgeState.state.update { it.copy(status = if (usingUSB) "Connected via USB" else "Connected", connected = true, pairing = false, macName = stored.name, error = "") }
                        liveDismissed = false
                        getSystemService(NotificationManager::class.java).notify(1, connectionNotification("Connected to ${stored.name}"))
                        heartbeatJob?.cancel(); heartbeatJob = scope.launch { while (isActive && authenticated) { delay(15_000); pumpQueue(); if (SystemClock.elapsedRealtime() - lastSeen > 50_000) { connection.close(); break }; write(Message("ping")); sendDeviceInfo(); sendBattery() } }
                        // Upgrade only between transfers. Never interrupt a live file to change routes.
                        if (!usingUSB) scope.launch {
                            while (isActive && authenticated && socket === connection && !usingUSB) {
                                delay(4000)
                                if (transfersIdle()) {
                                    val probe = runCatching { connectTLS(tls, "127.0.0.1", 38473, 1000) }.getOrNull()
                                    if (probe != null) {
                                        probe.close()
                                        if (socket === connection && transfersIdle()) { send(Message("usbSwitchRequest")) }
                                    }
                                }
                            }
                        }
                        recoveryJob?.join(); restoreQueueUI(); pumpQueue()
                        sendBattery(); sendDeviceInfo(); PhoneNotificationListener.instance?.publishCurrent()
                        refreshMedia()
                        continue
                    }
                    receiver.submit(message)
                }
            } catch (error: Exception) {
                if (currentCoroutineContext().isActive) showError(error.message ?: "Connection interrupted")
            } finally {
                receiver?.stop(); phoneFiles.reset()
                authenticated = false; usingUSB = false; heartbeatJob?.cancel(); runCatching { socket?.close() }; socket = null
                while (sendQueue.tryReceive().isSuccess) { /* Never carry clipboard or commands into the next session. */ }
                cleanupTransfers(); handler.post { stopRing(); if (!authenticated) media.stop() }
                BridgeState.state.update { it.copy(connected = false, pairing = false, status = "Disconnected") }
                getSystemService(NotificationManager::class.java).notify(1, connectionNotification("Waiting for your Mac"))
            }
            if (pairing?.token?.isNotEmpty() == true) break
            delay(delayMillis); delayMillis = (delayMillis * 2).coerceAtMost(15_000)
        }
    }
    fun send(message: Message): Boolean {
        val connection = socket ?: return false
        if (!authenticated) return false
        if (sendQueue.trySend(QueuedMessage(message, connection)).isFailure) {
            showError("Connection is busy; reconnecting")
            runCatching { socket?.close() }
            return false
        }
        return true
    }
    private fun write(message: Message, expectedSocket: SSLSocket? = null) {
        synchronized(sendLock) {
            val connection = socket ?: error("Not connected")
            check(expectedSocket == null || connection === expectedSocket) { "Transfer connection changed" }
            connection.outputStream.write(message.encode()); connection.outputStream.flush()
        }
    }
    private val phoneFiles by lazy { PhoneFiles(this) }
    private fun receive(message: Message) {
        if (!authenticated) return
        if (message.type == "_binaryChunk") {
            check(authenticated && supportsBinary) { "Binary transfer not negotiated" }
            receiveBinaryChunk(message.payload); return
        }
        if (message.type == "ack") return
        if (!seen.add(message.id)) { write(Message("ack", payload("messageID" to message.id))); return }
        if (seen.size > 2048) { val iterator = seen.iterator(); repeat(1024) { iterator.next(); iterator.remove() } }
        write(Message("ack", payload("messageID" to message.id)))
        val body = message.payload
        when (message.type) {
            "deviceInfo" -> {
                BridgeState.state.update { it.copy(macInfo = parseMacDeviceInfo(body)) }
            }
            "listPhoneFiles" -> send(phoneFiles.list(body.optString("folder"), body.optString("requestID"), body.optInt("offset", 0)))
            "downloadPhoneFile" -> {
                try { check(sendFiles(listOf(phoneFiles.file(body.optString("document"))))) { "Unable to queue this file. Check Bridge on Android." } }
                catch (error: Exception) { send(Message("error", payload("message" to (error.message ?: "Unable to download file")))) }
            }
            "usbSwitchReady" -> if (!usingUSB && transfersIdle()) { runCatching { socket?.close() } }
            "ping" -> write(Message("pong"))
            "pong" -> Unit
            "mediaCommand" -> handler.post { media.command(body.optString("sessionID"), body.optString("action")) }
            "refreshNotifications" -> PhoneNotificationListener.instance?.publishCurrent()
            "notificationReply" -> {
                val requestConnection = socket
                handler.post {
                if (!authenticated || socket !== requestConnection || !notificationRepliesSupported) return@post
                val token = body.optString("actionID")
                val result = PhoneNotificationListener.instance?.replyFromMac(body.optString("key"), token, body.optString("text"))
                    ?: NotificationReplyOutcome(false, "Notification access is unavailable on your phone.")
                send(Message("notificationReplyResult", payload("actionID" to token.take(80), "accepted" to result.accepted, "message" to result.message)))
                }
            }
            "notificationAction" -> handler.post {
                val token = body.optString("actionID")
                val accepted = PhoneNotificationListener.instance?.performFromMac(body.optString("key"), token) == true
                send(Message("notificationActionResult", payload("actionID" to token, "accepted" to accepted)))
            }
            "notificationDismiss" -> {
                val key = body.optString("key")
                val accepted = PhoneNotificationListener.instance?.dismissFromMac(key) == true
                write(Message("notificationDismissResult", payload("key" to key, "accepted" to accepted)))
            }
            "preferences" -> {
                mirrorEnabled = body.optBoolean("notifications", true); previewsEnabled = body.optBoolean("previews", false)
                PhoneNotificationListener.instance?.publishCurrent()
            }
            "clipboard" -> {
                val text = body.optString("text")
                if (text.isNotEmpty() && text.toByteArray().size <= Message.MAX_TEXT) {
                    if (getSharedPreferences("bridge", MODE_PRIVATE).getBoolean("clipboardHistory", false)) ClipboardHistory.session.record(text, pairing?.name ?: "Mac")
                    BridgeState.state.update { it.copy(clipboard = text) }
                    try {
                        getSystemService(ClipboardManager::class.java)
                            .setPrimaryClip(ClipData.newPlainText("From Mac", text))
                        getSystemService(NotificationManager::class.java).cancel(2)
                    } catch (_: SecurityException) {
                        BridgeState.state.update { it.copy(error = "Android blocked clipboard sync. You can copy the received text in Clipboard.") }
                    }
                }
            }
            "link" -> {
                val link = body.optString("url")
                if (validLink(link)) {
                    BridgeState.state.update { it.copy(link = link) }
                    val openIntent = Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    val open = PendingIntent.getActivity(this, 0, openIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    val notification = NotificationCompat.Builder(this, "handoff").setSmallIcon(R.drawable.ic_status)
                        .setContentTitle("Open link from your Mac?")
                        .setContentText("${Uri.parse(link).host} · Tap to open")
                        .setContentIntent(open).addAction(0, "Open link", open).setAutoCancel(true).build()
                    runCatching { getSystemService(NotificationManager::class.java).notify("bridge.link", 3, notification) }
                }
            }
            "fileOffer" -> offer(body)
            "fileAccept" -> startSending(body.optString("transferID"), body.optString("encoding") == "binary-v1")
            "fileReject" -> {
                val id = body.optString("transferID")
                synchronized(outgoingLock) {
                    if (outgoing.containsKey(id)) {
                        suppressedQueueIDs.add(id)
                        outgoing.remove(id)?.job?.cancel()
                        val reason = "Mac could not accept this file. Check Mac Bridge, then retry."
                        runCatching { fileQueue?.pauseAfterRejection(id, reason) }.onFailure { runCatching { fileQueue?.pauseSnapshot(id) }; showError("Queue pause failed: ${it.message}") }
                        BridgeState.updateTransfer(id, "Paused", 0f, failureReason = reason)
                    }
                }
                pumpQueue()
            }
            "fileFailed" -> {
                val id = body.optString("transferID")
                if (supportsTransferFailure && outgoing.containsKey(id)) failTransfer(id, body.optString("reason", "Receiver could not save file").take(240))
            }
            "fileCancel" -> cancelTransfer(body.optString("transferID"), notify = false)
            "fileChunk" -> receiveChunk(body)
            "fileProgress" -> {
                val id = body.optString("transferID"); val transfer = outgoing[id]
                val value = body.opt("receivedBytes")
                val received = if (value is Int || value is Long) value as Number else null
                val estimator = transfer?.estimator
                if (receiverProgress && transfer?.binary == true && received != null && estimator != null &&
                    estimator.record(received.toLong(), SystemClock.elapsedRealtime()) && BridgeState.state.value.transfers.any { it.id == id && it.status in listOf("Sending", "Finishing") }) {
                    val current = BridgeState.state.value.transfers.first { it.id == id }.status
                    val state = if (current == "Finishing" && estimator.bytes == transfer.size) "Verifying" else current
                    BridgeState.updateTransfer(id, state, estimator.bytes.toFloat() / transfer.size.coerceAtLeast(1), bytesPerSecond = estimator.rate)
                }
            }
            "fileComplete" -> finishReceiving(body.optString("transferID"))
            "fileReceived" -> {
                val id = body.optString("transferID")
                synchronized(outgoingLock) {
                val transfer = outgoing[id]
                val status = BridgeState.state.value.transfers.firstOrNull { it.id == id }?.status
                // A receipt must follow the sender's completion frame, never an
                // offer or a still-running send.
                val entry = fileQueue?.all()?.firstOrNull { it.id == id }
                val priorReceipt = status == "Waiting for Mac" && body.optBoolean("alreadyReceived") && entry != null && body.optString("sha256") == entry.hash && body.optLong("size", -1) == entry.size
                if (transfer != null && (status in listOf("Finishing", "Verifying") || priorReceipt)) {
                    outgoing.remove(id)?.job?.cancel()
                    fileQueue?.remove(id)
                    BridgeState.updateTransfer(id, "Complete", 1f)
                }
                }
                pumpQueue()
            }
            "ring" -> handler.post { if (body.optBoolean("start")) startRing() else stopRing() }
            "unpair" -> { clearPairing(); handler.post { stopSelf() } }
            "error" -> showError(body.optString("message").take(240))
        }
    }
    fun sendText(text: String, consent: ClipboardConsent? = null): Boolean {
        if (text.isBlank() || text.toByteArray().size > Message.MAX_TEXT) { showError("Send between 1 byte and 32 KB of text"); return false }
        val approved = consent?.consume(text) == true
        if (ClipboardProtection.reason(text) != null && !approved) {
            showError("Sensitive text needs Send once confirmation"); return false
        }
        return send(Message("clipboard", payload("text" to text)))
    }
    fun sendLink(text: String, consent: ClipboardConsent? = null, title: String = ""): Boolean {
        if (!validLink(text)) return false
        val approved = consent?.consume(text) == true
        if (ClipboardProtection.reason(text) != null && !approved) {
            showError("Sensitive link needs Send once confirmation"); return false
        }
        return send(Message("link", payload("url" to text, "title" to handoffTitle(title))))
    }
    fun refreshMedia() { handler.post { if (authenticated) media.refresh() else media.stop() } }
    private fun sendDeviceInfo() {
        val memory = ActivityManager.MemoryInfo()
        getSystemService(ActivityManager::class.java).getMemoryInfo(memory)
        val storage = StatFs(Environment.getDataDirectory().absolutePath)
        send(Message("deviceInfo", payload("model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "os" to Build.VERSION.RELEASE, "securityPatch" to Build.VERSION.SECURITY_PATCH,
            "chip" to (if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else Build.HARDWARE),
            "cores" to Runtime.getRuntime().availableProcessors(), "memoryTotal" to memory.totalMem,
            "memoryAvailable" to memory.availMem, "storageFree" to storage.availableBytes, "storageTotal" to storage.totalBytes)))
    }
    private fun sendBattery() { registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let { batteryReceiver.onReceive(this, it) } }
    private fun startRing() {
        stopRing()
        if (getSharedPreferences("bridge", MODE_PRIVATE).getBoolean("findPhoneFlashlight", false)) runCatching { torch.start(); findTorchActive = true }.onFailure { showError("Flashlight unavailable: ${it.message}") }
        val soundAllowed = getSystemService(AudioManager::class.java).ringerMode == AudioManager.RINGER_MODE_NORMAL
        if (soundAllowed) {
            val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = RingtoneManager.getRingtone(this, sound)?.apply {
                audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build()
                isLooping = true; play()
            }
        } else if (!findTorchActive) showError("Phone is silent or on vibrate; ringing respects your sound settings")
        val finding = ringtone?.isPlaying == true || findTorchActive
        BridgeState.state.update { it.copy(ringing = finding) }
        send(Message("ringState", payload("ringing" to finding)))
        if (finding) handler.postDelayed(ringTimeout, 30_000)
    }
    fun stopFindFlashlight() { torch.stop(); findTorchActive = false; val ringing = ringtone?.isPlaying == true; BridgeState.state.update { it.copy(ringing = ringing) }; send(Message("ringState", payload("ringing" to ringing))) }
    fun stopRing() {
        handler.removeCallbacks(ringTimeout)
        torch.stop(); findTorchActive = false; ringtone?.stop(); ringtone = null; BridgeState.state.update { it.copy(ringing = false) }
        send(Message("ringState", payload("ringing" to false)))
    }
    private fun offer(body: JSONObject) {
        val id = body.optString("transferID"); val name = body.optString("name"); val size = body.optLong("size", -1)
        synchronized(incomingLock) {
            if ((body.optString("encoding") == "binary-v1" && !supportsBinary) || outgoing.containsKey(id) || preparing.contains(id) || runCatching { UUID.fromString(id) }.isFailure || !validFileName(name) || size !in 0..MAX_FILE_BYTES ||
                !validHash(body.optString("sha256")) || offers.containsKey(id) || incoming.containsKey(id) || offers.size + incoming.size >= 3) {
                send(Message("fileReject", payload("transferID" to id))); return
            }
            val peer = pairing?.fingerprint ?: return
            if (receipts.matches(peer, id, name, size, body.optString("sha256"))) {
                send(Message("fileReceived", payload("transferID" to id, "alreadyReceived" to true, "sha256" to body.optString("sha256"), "size" to size))); return
            }
            offers[id] = body
            BridgeState.addTransfer(Transfer(id, name, size, true, if (autoReceiveFile(size)) "Preparing download" else "Choose save location"))
        }
        if (autoReceiveFile(size)) acceptTransfer(id) else fileNotification(id, name, "Accept and choose where to save", true)
    }
    fun offeredFileName(id: String): String? = offers[id]?.optString("name")
    fun acceptTransfer(id: String, destination: Uri? = null) {
        scope.launch {
            recoveryJob?.join()
            synchronized(incomingLock) {
                val offer = offers[id] ?: run {
                    destination?.let { uri ->
                        if (incoming.values.none { it.uri == uri } && BridgeState.state.value.transfers.none { it.path == uri.toString() }) deleteDestination(uri, false)
                    }
                    return@launch
                }
                val size = offer.getLong("size")
                if (!autoReceiveFile(size) && destination == null) { showError("Choose a save location for this large file"); return@launch }
                var uri: Uri? = destination
                val mediaStore = destination == null
                try {
                    check(authenticated) { "Connect to your Mac first" }
                    if (mediaStore) {
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, offer.getString("name"))
                            put(MediaStore.Downloads.MIME_TYPE, android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(offer.getString("name").substringAfterLast('.', "").lowercase()) ?: "application/octet-stream")
                            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/FromMac/")
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }
                        uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: error("Cannot create Downloads/FromMac file")
                        trackPendingDownload(uri, true)
                    }
                    val target = uri ?: error("No save location")
                    if (!mediaStore) {
                        contentResolver.takePersistableUriPermission(target, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        trackPendingDocument(target, true, size, offer.getString("sha256"))
                    }
                    val output = (contentResolver.openOutputStream(target, "w") ?: error("Cannot write selected destination")).buffered(1_048_576)
                    incoming[id] = Incoming(target, mediaStore, output, size, offer.getString("sha256"), offer.optString("encoding") == "binary-v1")
                    offers.remove(id)
                    getSystemService(NotificationManager::class.java).cancel("file.$id", 2)
                    BridgeState.updateTransfer(id, "Receiving")
                    write(Message("fileAccept", payload("transferID" to id, "encoding" to if (incoming[id]?.binary == true) "binary-v1" else "json")))
                } catch (error: Exception) {
                    if (!incoming.containsKey(id)) uri?.let { deleteDestination(it, mediaStore) }
                    failTransfer(id, error.message ?: "Cannot receive file")
                }
            }
        }
    }
    private fun trackPendingDownload(uri: Uri, add: Boolean) {
        val prefs = getSharedPreferences("incomingDownloads", MODE_PRIVATE)
        val tracked = prefs.getStringSet("pending", emptySet()).orEmpty().toMutableSet()
        if (add) tracked.add(uri.toString()) else tracked.remove(uri.toString())
        check(prefs.edit().putStringSet("pending", tracked).commit()) { "Cannot track pending download" }
    }
    private fun cleanupPendingDownloads() {
        val prefs = getSharedPreferences("incomingDownloads", MODE_PRIVATE)
        prefs.getStringSet("pending", emptySet()).orEmpty().toList().forEach { value ->
            val uri = Uri.parse(value)
            runCatching {
                val pending = contentResolver.query(uri, arrayOf(MediaStore.Downloads.IS_PENDING), null, null, null)?.use { it.moveToFirst() && it.getInt(0) == 1 } ?: false
                if (!pending || contentResolver.delete(uri, null, null) > 0) trackPendingDownload(uri, false)
            }
        }
    }
    private fun trackPendingDocument(uri: Uri, add: Boolean, size: Long = 0, hash: String = "") {
        val prefs = getSharedPreferences("incomingDocuments", MODE_PRIVATE)
        val tracked = prefs.getStringSet("pending", emptySet()).orEmpty().toMutableSet()
        if (add) tracked.add(uri.toString()) else tracked.remove(uri.toString())
        val edit = prefs.edit().putStringSet("pending", tracked)
        if (add) edit.putString("meta.$uri", payload("size" to size, "hash" to hash).toString()) else edit.remove("meta.$uri")
        check(edit.commit()) { "Cannot track selected file" }
    }
    private fun cleanupPendingDocuments() {
        val prefs = getSharedPreferences("incomingDocuments", MODE_PRIVATE)
        prefs.getStringSet("pending", emptySet()).orEmpty().toList().forEach { value ->
            val uri = Uri.parse(value)
            runCatching {
                // A process can die after close but before clearing the journal.
                // Preserve a fully verified file rather than deleting a completed save.
                val meta = JSONObject(prefs.getString("meta.$uri", "{}").orEmpty())
                val expectedSize = meta.optLong("size", -1)
                val expectedHash = meta.optString("hash")
                var bytes = 0L
                val digest = MessageDigest.getInstance("SHA-256")
                val verified = runCatching {
                    contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = ByteArray(65_536)
                        while (true) {
                            if (!scope.isActive) error("Cleanup interrupted")
                            val count = input.read(buffer); if (count < 0) break
                            bytes += count; check(bytes <= expectedSize)
                            digest.update(buffer, 0, count)
                        }
                    } ?: error("Cannot inspect partial document")
                    bytes == expectedSize && digest.digest().hex() == expectedHash
                }.getOrNull()
                if (verified == true || (verified == false && DocumentsContract.deleteDocument(contentResolver, uri))) {
                    trackPendingDocument(uri, false)
                    contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }
            }
        }
    }
    private fun deleteDestination(uri: Uri, mediaStore: Boolean) {
        val deleted = runCatching {
            if (mediaStore) contentResolver.delete(uri, null, null) > 0 else DocumentsContract.deleteDocument(contentResolver, uri)
        }.getOrDefault(false)
        // Keep recovery records and grants if a provider cannot delete yet.
        if (deleted) {
            if (mediaStore) runCatching { trackPendingDownload(uri, false) }
            else {
                runCatching { trackPendingDocument(uri, false) }
                runCatching { contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            }
        }
    }
    private fun fileNotification(id: String, name: String, text: String, choose: Boolean) {
        val intent = Intent(this, MainActivity::class.java).setAction("file.$id")
        if (choose) intent.putExtra("receiveTransferID", id)
        val open = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = NotificationCompat.Builder(this, "files").setSmallIcon(R.drawable.ic_status)
            .setContentTitle(name).setContentText(text).setContentIntent(open).setAutoCancel(true)
        if (choose) builder.addAction(0, "Accept & choose location", open)
        runCatching { getSystemService(NotificationManager::class.java).notify("file.$id", 2, builder.build()) }
    }
    private fun receiveChunk(body: JSONObject) {
        synchronized(incomingLock) {
        val id = body.optString("transferID"); val transfer = incoming[id] ?: return
        if (transfer.binary) { failTransfer(id, "Incorrect transfer encoding"); return }
        try {
            val data = Base64.decode(body.getString("data"), Base64.NO_WRAP)
            require(data.isNotEmpty() && data.size <= Message.CHUNK_SIZE && body.getLong("sequence") == transfer.sequence && transfer.bytes + data.size <= transfer.size)
            transfer.output.write(data); transfer.digest.update(data); transfer.bytes += data.size; transfer.sequence++
            BridgeState.updateTransfer(id, "Receiving", transfer.bytes.toFloat() / transfer.size.coerceAtLeast(1))
        } catch (error: Exception) { failTransfer(id, "Invalid or unwritable file chunk") }
            }
    }
    private fun receiveBinaryChunk(body: JSONObject) {
        synchronized(incomingLock) {
            val id = body.optString("transferID"); val transfer = incoming[id] ?: return
            try {
                check(transfer.binary) { "Incorrect transfer encoding" }
                val bytes = body.opt("data") as? ByteArray ?: error("Invalid binary data")
                require(bytes.isNotEmpty() && bytes.size <= BINARY_CHUNK_SIZE && body.getLong("sequence") == transfer.sequence && transfer.bytes + bytes.size <= transfer.size)
                transfer.output.write(bytes); transfer.digest.update(bytes)
                transfer.bytes += bytes.size; transfer.sequence++
                val now = SystemClock.elapsedRealtime()
                if (receiverProgress && (now - transfer.lastReport >= 500 || transfer.bytes == transfer.size)) {
                    transfer.lastReport = now
                    send(Message("fileProgress", payload("transferID" to id, "receivedBytes" to transfer.bytes)))
                }
                if (now - transfer.lastUI >= 250 || transfer.bytes == transfer.size) {
                    transfer.lastUI = now
                    BridgeState.updateTransfer(id, "Receiving", transfer.bytes.toFloat() / transfer.size.coerceAtLeast(1), bytesPerSecond = transfer.bytes * 1000.0 / (now - transfer.started).coerceAtLeast(1))
                }
            } catch (error: Exception) { failTransfer(id, error.message ?: "Invalid binary chunk") }
        }
    }
    private fun finishReceiving(id: String) {
        synchronized(incomingLock) {
            val transfer = incoming[id] ?: return
            try {
                BridgeState.updateTransfer(id, "Verifying")
                require(transfer.bytes == transfer.size && transfer.digest.digest().hex() == transfer.hash) { "File integrity check failed" }
                transfer.output.close()
                if (!transfer.mediaStore) trackPendingDocument(transfer.uri, false)
                if (transfer.mediaStore) {
                    val updated = contentResolver.update(transfer.uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                    check(updated == 1) { "Could not publish download" }
                    runCatching { trackPendingDownload(transfer.uri, false) }
                }
                val name = BridgeState.state.value.transfers.firstOrNull { it.id == id }?.name ?: "File"
                pairing?.fingerprint?.let { receipts.record(it, id, name, transfer.size, transfer.hash) }
                incoming.remove(id); BridgeState.updateTransfer(id, "Complete", 1f, transfer.uri.toString())
                runCatching { write(Message("fileReceived", payload("transferID" to id))) }.onFailure { runCatching { socket?.close() } }
                fileNotification(id, name, if (transfer.mediaStore) "Saved to Downloads/FromMac" else "Saved to your chosen location", false)
            } catch (error: Exception) { failTransfer(id, error.message ?: "Cannot save file") }
        }
    }
    fun sendFiles(uris: List<Uri>): Boolean {
        val peer = pairing?.takeIf { it.token.isEmpty() } ?: run { showError("Pair your Mac first"); return false }
        val queue = fileQueue ?: run { showError("Transfer queue is unavailable"); return false }
        val files = uris.distinct()
        if (files.any { it.scheme != "content" && !(it.scheme == "file" && it.path?.let { path -> FolderArchive.isStagedSource(File(path), cacheDir) } == true) }) {
            showError("Choose files through the system picker or a content-sharing app")
            return false
        }
        synchronized(outgoingLock) {
            if (files.isEmpty()) return false
            if (files.size + queue.all().size + preparing.size > 100) { showError("The queue holds up to 100 files"); return false }
            files.forEach { uri ->
                val id = UUID.randomUUID().toString(); preparing.add(id)
                prepareQueuedFile(uri, id, queuePeer(peer))
            }
        }
        return true
    }
    fun sendFile(uri: Uri) { sendFiles(listOf(uri)) }
    private fun prepareQueuedFile(uri: Uri, id: String, peer: String) {
        scope.launch {
            recoveryJob?.join()
            val queue = fileQueue ?: return@launch
            val cache = File(queue.directory, "$id.part")
            try {
                val name = if (uri.scheme == "file") File(uri.path ?: error("Invalid file")).name else contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Shared file"
                require(validFileName(name)) { "Unsupported file name" }
                val hash = MessageDigest.getInstance("SHA-256"); var size = 0L
                BridgeState.addTransfer(Transfer(id, name, 0, false, "Preparing"))
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(cache).use { output ->
                        val buffer = ByteArray(65_536)
                        while (true) {
                            ensureActive(); check(preparing.contains(id) && pairing?.let(::queuePeer) == peer) { "Transfer cancelled" }
                            val count = input.read(buffer); if (count < 0) break
                            size += count; require(size <= MAX_FILE_BYTES) { "File exceeds 16 GiB" }
                            check(queue.directory.usableSpace > 512L * 1024 * 1024) { "Free more space to queue this file" }
                            output.write(buffer, 0, count); hash.update(buffer, 0, count)
                        }
                        output.fd.sync()
                    }
                } ?: error("Cannot open shared file")
                synchronized(outgoingLock) {
                    check(preparing.contains(id) && pairing?.let(::queuePeer) == peer) { "Transfer cancelled" }
                    check(cache.renameTo(queue.payload(id))) { "Cannot save queued file" }
                    try { queue.add(QueuedFile(id, peer, name, size, hash.digest().hex(), System.currentTimeMillis())) }
                    catch (error: Exception) { queue.payload(id).delete(); throw error }
                    preparing.remove(id)
                }
                BridgeState.state.update { ui -> ui.copy(transfers = ui.transfers.map { if (it.id == id) it.copy(size = size, status = "Queued") else it }) }
                pumpQueue()
            } catch (error: Exception) {
                cache.delete()
                if (preparing.remove(id)) { BridgeState.updateTransfer(id, "Failed"); showError(error.message ?: "Cannot queue file") }
            } finally {
                // Generated folder archives are app-owned staging files only.
                cleanupFolderStage(uri)
            }
        }
    }
    private fun cleanupFolderStage(uri: Uri) {
        if (uri.scheme == "file") runCatching {
            val source = File(uri.path ?: "")
            if (FolderArchive.isStagedSource(source, cacheDir)) FolderArchive.remove(source)
        }
    }
    private fun queuePeer(peer: Pairing): String = sha256((peer.fingerprint + "\u0000" + peer.credential).toByteArray())
    private fun restoreQueueUI() {
        val peer = pairing?.let(::queuePeer) ?: return
        fileQueue?.all()?.filter { it.peer == peer }?.forEach { entry ->
            if (BridgeState.state.value.transfers.none { it.id == entry.id }) BridgeState.addTransfer(Transfer(entry.id, entry.name, entry.size, false, if (entry.paused) "Paused" else "Queued", failureReason = entry.error))
        }
    }
    private fun pumpQueue() {
        val queue = fileQueue ?: return
        val connection = socket ?: return
        if (!authenticated) return
        synchronized(outgoingLock) {
            queue.all().filter { it.peer == pairing?.let(::queuePeer) && !it.paused && it.retryAfter <= System.currentTimeMillis() }.forEach { entry ->
                if (outgoing.size >= 3 || outgoing.containsKey(entry.id) || suppressedQueueIDs.contains(entry.id)) return@forEach
                val file = queue.payload(entry.id)
                if (!file.isFile || file.length() != entry.size) {
                    suppressedQueueIDs.add(entry.id)
                    runCatching { queue.update(entry.copy(paused = true, error = "Queued snapshot is missing")) }; BridgeState.updateTransfer(entry.id, "Paused", failureReason = "Queued snapshot is missing"); return@forEach
                }
                outgoing[entry.id] = Outgoing(file, entry.size, supportsBinary)
                BridgeState.updateTransfer(entry.id, "Waiting for Mac", 0f)
                send(Message("fileOffer", payload("transferID" to entry.id, "name" to entry.name, "size" to entry.size, "sha256" to entry.hash, "encoding" to if (supportsBinary) "binary-v1" else "json")))
            }
        }
    }
    fun pauseTransfer(id: String) {
        synchronized(outgoingLock) {
            val entry = fileQueue?.all()?.firstOrNull { it.id == id } ?: return
            suppressedQueueIDs.add(id)
            runCatching { fileQueue?.update(entry.copy(paused = true)) }.onFailure {
                runCatching { fileQueue?.pauseSnapshot(id) }
                showError("Paused; queue metadata update failed: ${it.message}")
            }
            outgoing.remove(id)?.job?.cancel(); BridgeState.updateTransfer(id, "Paused", 0f)
        }
        send(Message("fileCancel", payload("transferID" to id))); pumpQueue()
    }
    fun resumeTransfer(id: String) {
        synchronized(outgoingLock) {
            val entry = fileQueue?.all()?.firstOrNull { it.id == id } ?: return
            fileQueue?.resumeSnapshot(id)
            fileQueue?.update(entry.copy(paused = false, attempts = 0, retryAfter = 0, error = ""))
            suppressedQueueIDs.remove(id)
            BridgeState.updateTransfer(id, "Queued", 0f, failureReason = "")
        }
        pumpQueue()
    }
    private fun startSending(id: String, binary: Boolean = false) {
        synchronized(outgoingLock) {
        val transferSocket = socket ?: return
        val transfer = outgoing[id] ?: return
        if (transfer.job != null) return
        if (binary && (!transfer.binary || !supportsBinary)) { failTransfer(id, "Invalid binary negotiation"); return }
        val useReceiverProgress = binary && receiverProgress
        transfer.estimator = TransferRateEstimator(transfer.size, SystemClock.elapsedRealtime())
        transfer.job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                BridgeState.updateTransfer(id, "Sending"); var sequence = 0L; var sent = 0L
                val started = SystemClock.elapsedRealtime(); var lastUI = started
                transfer.file.inputStream().use { input ->
                    val buffer = ByteArray(if (binary) BINARY_CHUNK_SIZE else Message.CHUNK_SIZE)
                    while (true) {
                        ensureActive(); val count = input.read(buffer); if (count < 0) break
                        ensureActive()
                        if (binary) {
                            val frame = encodeBinaryChunk(id, sequence++, buffer, count)
                            synchronized(sendLock) {
                                val connection = socket ?: error("Not connected")
                                check(connection === transferSocket && outgoing[id] === transfer) { "Transfer cancelled or connection changed" }
                                connection.outputStream.write(frame)
                            }
                        } else synchronized(sendLock) {
                            check(outgoing[id] === transfer && socket === transferSocket) { "Transfer cancelled or connection changed" }
                            write(Message("fileChunk", payload("transferID" to id, "sequence" to sequence++, "data" to Base64.encodeToString(buffer.copyOf(count), Base64.NO_WRAP))), transferSocket)
                        }
                        sent += count
                        val now = SystemClock.elapsedRealtime()
                        if (now - lastUI >= 250 || sent == transfer.size) {
                            lastUI = now
                            if (!useReceiverProgress) BridgeState.updateTransfer(id, "Sending", sent.toFloat() / transfer.size.coerceAtLeast(1), bytesPerSecond = sent * 1000.0 / (now - started).coerceAtLeast(1))
                        }
                    }
                }
                ensureActive(); check(sent == transfer.size)
                if (useReceiverProgress) {
                    val received = transfer.estimator?.bytes ?: 0
                    BridgeState.updateTransfer(id, if (received == transfer.size) "Verifying" else "Finishing")
                } else BridgeState.updateTransfer(id, "Verifying", 1f)
                synchronized(sendLock) { check(outgoing[id] === transfer); write(Message("fileComplete", payload("transferID" to id)), transferSocket) }
            } catch (error: Exception) { if (currentCoroutineContext().isActive && outgoing[id] === transfer) failTransfer(id, error.message ?: "Transfer interrupted") }
        }
            transfer.job?.start()
        }
    }
    fun cancelTransfer(id: String, notify: Boolean = true) {
        synchronized(outgoingLock) {
            if (fileQueue?.all()?.any { it.id == id } == true) suppressedQueueIDs.add(id)
            preparing.remove(id)
            outgoing.remove(id)?.job?.cancel()
            runCatching { if (fileQueue?.all()?.any { it.id == id } == true) fileQueue?.remove(id); suppressedQueueIDs.remove(id) }.onFailure { runCatching { fileQueue?.payload(id)?.delete(); File(fileQueue?.directory, "$id.paused").delete() }; showError("Transfer cancelled; queue cleanup failed: ${it.message}") }
            BridgeState.updateTransfer(id, "Cancelled")
        }
        synchronized(incomingLock) {
            offers.remove(id)
            incoming.remove(id)?.let { runCatching { it.output.close() }; deleteDestination(it.uri, it.mediaStore) }
        }
        getSystemService(NotificationManager::class.java).cancel("file.$id", 2)
        if (notify) send(Message("fileCancel", payload("transferID" to id)))
        pumpQueue()
    }
    private fun failTransfer(id: String, reason: String) {
        val retry = synchronized(outgoingLock) {
            val entry = fileQueue?.all()?.firstOrNull { it.id == id }
            if (entry == null) false else {
                outgoing.remove(id)?.job?.cancel()
                val failed = fileQueue?.recordFailure(id, reason) ?: return@synchronized false
                val attempts = failed.attempts
                BridgeState.updateTransfer(id, if (entry.paused || attempts >= 3) "Paused" else "Retrying", 0f, failureReason = reason)
                showError(if (attempts >= 3) "${entry.name} paused after three attempts. Retry or remove it in Activity." else "${entry.name} will retry. $reason")
                true
            }
        }
        if (retry) { send(Message("fileCancel", payload("transferID" to id))); pumpQueue() }
        else {
            val wasReceiving = offers.containsKey(id) || incoming.containsKey(id)
            cancelTransfer(id, notify = false)
            if (wasReceiving) send(Message(if (supportsTransferFailure) "fileFailed" else "fileReject", payload("transferID" to id, "reason" to reason.take(240))))
            BridgeState.updateTransfer(id, "Failed"); showError(reason)
        }
    }
    private fun cleanupTransfers() {
        // Incoming partials are discarded; peer-bound preparation continues offline.
        // Unpair clears preparing, and service destruction cancels its scope.
        (offers.keys + incoming.keys).toSet().forEach { cancelTransfer(it, notify = false) }
        synchronized(outgoingLock) {
        outgoing.keys.toList().forEach { id ->
            outgoing.remove(id)?.job?.cancel()
            val paused = fileQueue?.all()?.firstOrNull { it.id == id }?.paused == true
            BridgeState.updateTransfer(id, if (paused) "Paused" else "Queued", 0f)
        }
        }
    }
    private fun showError(error: String) { BridgeState.state.update { it.copy(error = error.take(300)) } }
    private fun clearPairing(notify: Boolean = false) {
        val oldConnection = synchronized(outgoingLock) {
            val previous = if (notify && authenticated) socket else null
            authenticated = false; secure.clear(); pairing = null; preparing.clear(); suppressedQueueIDs.clear()
            outgoing.values.forEach { it.job?.cancel() }; outgoing.clear()
            runCatching { fileQueue?.clear() }.onFailure { showError("Queue cleanup failed: ${it.message}") }
            previous
        }
        if (oldConnection != null) {
            // Revoke locally first. A best-effort final control packet never delays revocation.
            handler.postDelayed({ runCatching { oldConnection.close() } }, 1000)
            CoroutineScope(Dispatchers.IO).launch {
                runCatching { synchronized(sendLock) { oldConnection.outputStream.write(Message("unpair").encode()); oldConnection.outputStream.flush() } }
                runCatching { oldConnection.close() }
            }
        } else runCatching { socket?.close() }
        cleanupTransfers(); ClipboardHistory.session.clear(); receipts.clear()
        handler.post { stopRing(); media.stop() }
        getSharedPreferences("bridge", MODE_PRIVATE).edit().putBoolean("enabled", false).apply()
        BridgeState.state.value = UIState()
    }
    fun refreshConnectionNotification() {
        liveDismissed = false
        if (authenticated) getSystemService(NotificationManager::class.java).notify(1, connectionNotification("Connected to ${pairing?.name ?: "your Mac"}"))
    }
    private fun connectionNotification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, BridgeService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val dismiss = PendingIntent.getService(this, 2, Intent(this, BridgeService::class.java).setAction(ACTION_LIVE_DISMISS), PendingIntent.FLAG_IMMUTABLE)
        val transfer = if (authenticated) BridgeState.state.value.transfers.firstOrNull { it.status in setOf("Preparing", "Sending", "Receiving", "Finishing", "Verifying") } else null
        val progress = transfer?.let { (it.progress.coerceIn(0f, 1f) * 100).toInt() }
        val standard = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(if (authenticated) R.drawable.ic_status_connected else R.drawable.ic_status)
            .setContentTitle(if (authenticated) "Bridge active" else "Bridge")
            .setContentText(transfer?.let { "${it.status} · ${it.name}" } ?: text).setContentIntent(open).setDeleteIntent(dismiss).addAction(0, "Disconnect", stop)
            .setCategory(NotificationCompat.CATEGORY_SERVICE).setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true).setShowWhen(false).setBadgeIconType(NotificationCompat.BADGE_ICON_NONE)
            .setColor(0xFF3468E8.toInt()).setSubText(if (authenticated) "${if (usingUSB) "USB" else "Wi-Fi"} · Encrypted" else "Private device connection")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setOngoing(true).setOnlyAlertOnce(true).build()
        if (Build.VERSION.SDK_INT >= 36) {
            val live = Notification.Builder.recoverBuilder(this, standard)
                .setRequestPromotedOngoing(authenticated && getSharedPreferences("bridge", MODE_PRIVATE).getBoolean("liveConnection", true))
                .setShortCriticalText(progress?.let { "$it%" } ?: if (authenticated) "Linked" else "")
            if (transfer != null) live.setStyle(Notification.ProgressStyle()
                .addProgressSegment(Notification.ProgressStyle.Segment(100).setColor(0xFF3468E8.toInt()))
                .setProgress(progress ?: 0).setProgressIndeterminate(transfer.status == "Preparing"))
            return live.build()
        }
        return standard
    }
    @Suppress("DEPRECATION") private fun startDiscovery() {
        if (discovery != null) return
        val manager = getSystemService(NsdManager::class.java)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) { discovery = null }
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            override fun onServiceLost(info: NsdServiceInfo) { destinations.remove(info.serviceName) }
            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceName != pairing?.service) return
                runCatching { manager.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) = Unit
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        if (info.serviceName != pairing?.service || info.port !in 1..65535) return
                        info.host?.hostAddress?.let { destinations[info.serviceName] = it to info.port }
                    }
                }) }
            }
        }
        discovery = listener
        runCatching { manager.discoverServices("_bridge._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { discovery = null }
    }
    override fun onDestroy() {
        authenticated = false; sendQueue.close(); scope.cancel(); runCatching { socket?.close() }; cleanupTransfers(); stopRing()
        runCatching { unregisterReceiver(batteryReceiver) }
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback) }
        discovery?.let { runCatching { getSystemService(NsdManager::class.java).stopServiceDiscovery(it) } }
        BridgeState.state.update { it.copy(connected = false, pairing = false, status = "Disconnected") }
        media.stop(); instance = null; super.onDestroy()
    }
}
