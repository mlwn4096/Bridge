package dev.bridge.companion

import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.app.KeyguardManager
import android.os.Build
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Base64
import java.io.ByteArrayOutputStream
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import java.util.UUID

class PhoneNotificationListener : NotificationListenerService() {
    companion object { @Volatile var instance: PhoneNotificationListener? = null }
    private data class ExposedAction(val token: String, val action: Notification.Action, val postedAt: Long, val lease: NotificationActionLease = NotificationActionLease(SystemClock.elapsedRealtime()))
    private val actions = LinkedHashMap<String, List<ExposedAction>>()
    override fun onListenerConnected() { instance = this; publishCurrent(); BridgeService.instance?.refreshMedia() }
    @Synchronized override fun onListenerDisconnected() { actions.clear(); instance = null }
    @Synchronized override fun onDestroy() { actions.clear(); instance = null; super.onDestroy() }
    override fun onNotificationPosted(notification: StatusBarNotification) { publish(notification) }
    @Synchronized override fun onNotificationRemoved(notification: StatusBarNotification) {
        actions.remove(notification.key)
        if (notification.packageName != packageName) BridgeService.instance?.send(Message("notificationRemoved", payload("key" to notification.key)))
    }
    fun publishCurrent() { runCatching { activeNotifications?.filterNotNull()?.take(100)?.forEach { publish(it) } } }
    fun dismissFromMac(key: String): Boolean {
        val service = BridgeService.instance ?: return false
        if (!service.mirrorEnabled || key.length > 512) return false
        val item = runCatching { activeNotifications?.firstOrNull { it.key == key } }.getOrNull() ?: return false
        val excluded = getSharedPreferences("bridge", MODE_PRIVATE).getStringSet("excludedApps", emptySet()).orEmpty()
        if (item.packageName == packageName || item.packageName in excluded || !item.isClearable) return false
        return runCatching { cancelNotification(key); true }.getOrDefault(false)
    }
    private fun eligible(action: Notification.Action): Boolean = action.actionIntent != null &&
        !action.actionIntent.isActivity && action.remoteInputs.isNullOrEmpty() && action.dataOnlyRemoteInputs.isNullOrEmpty() &&
        (Build.VERSION.SDK_INT < 31 || !action.isAuthenticationRequired)
    private fun replyInput(action: Notification.Action): RemoteInput? {
        val intent = action.actionIntent ?: return null
        if (intent.isActivity || (Build.VERSION.SDK_INT >= 31 && (intent.isImmutable || action.isAuthenticationRequired)) ||
            !action.dataOnlyRemoteInputs.isNullOrEmpty()) return null
        val input = action.remoteInputs?.singleOrNull() ?: return null
        return input.takeIf { it.allowFreeFormInput && !it.resultKey.isNullOrBlank() }
    }
    @Synchronized fun replyFromMac(key: String, token: String, text: String): NotificationReplyOutcome {
        fun rejected(message: String) = NotificationReplyOutcome(false, message)
        val service = BridgeService.instance ?: return rejected("Connect your phone first.")
        if (!service.notificationRepliesSupported || !service.mirrorEnabled || !service.previewsEnabled)
            return rejected("Enable notification sharing and previews before replying.")
        if (key.length > 512 || !NotificationReplyPolicy.validText(text)) return rejected("Enter a reply of up to 4096 UTF-8 bytes.")
        if (getSystemService(KeyguardManager::class.java).isDeviceLocked) return rejected("Unlock your phone before replying.")
        val exposed = actions[key]?.firstOrNull { it.token == token && replyInput(it.action) != null }
            ?: return rejected("This reply action changed or was already used. Open the latest notification.")
        if (!exposed.lease.usable(SystemClock.elapsedRealtime()))
            return rejected("Reply action expired. Refresh notifications and try again.")
        val item = runCatching { activeNotifications?.firstOrNull { it.key == key } }.getOrNull()
            ?: return rejected("This notification was removed.")
        val excluded = getSharedPreferences("bridge", MODE_PRIVATE).getStringSet("excludedApps", emptySet()).orEmpty()
        if (item.packageName == packageName || item.packageName in excluded || item.postTime != exposed.postedAt)
            return rejected("This notification is no longer available for replies.")
        val originalInput = replyInput(exposed.action) ?: return rejected("Reply is unsupported.")
        val current = item.notification.actions?.firstOrNull {
            it.actionIntent == exposed.action.actionIntent && it.title == exposed.action.title && replyInput(it)?.resultKey == originalInput.resultKey
        } ?: return rejected("This reply action changed. Open the latest notification.")
        val input = replyInput(current) ?: return rejected("Reply is unsupported.")
        // Consume before invoking the app, even if it rejects the PendingIntent.
        if (!exposed.lease.consume(SystemClock.elapsedRealtime())) return rejected("Reply action expired or was already used.")
        actions[key] = actions[key].orEmpty().filterNot { it.token == token }
        return runCatching {
            val intent = Intent()
            val results = Bundle().apply { putCharSequence(input.resultKey, text) }
            RemoteInput.addResultsToIntent(arrayOf(input), intent, results)
            RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
            current.actionIntent.send(this, 0, intent)
            NotificationReplyOutcome(true, "Reply handed to the phone app. Check the conversation for delivery.")
        }.getOrElse { rejected("The phone app rejected this reply. Check the conversation before trying again.") }
    }
    @Synchronized fun performFromMac(key: String, token: String): Boolean {
        val service = BridgeService.instance ?: return false
        if (!service.mirrorEnabled || !service.previewsEnabled || getSystemService(KeyguardManager::class.java).isDeviceLocked) return false
        val exposed = actions[key]?.firstOrNull { it.token == token } ?: return false
        val item = runCatching { activeNotifications?.firstOrNull { it.key == key } }.getOrNull() ?: return false
        val excluded = getSharedPreferences("bridge", MODE_PRIVATE).getStringSet("excludedApps", emptySet()).orEmpty()
        if (item.packageName in excluded || item.packageName == packageName || item.postTime != exposed.postedAt) return false
        val current = item.notification.actions?.firstOrNull { it.actionIntent == exposed.action.actionIntent && it.title == exposed.action.title && eligible(it) } ?: return false
        // Each advertised action token is single-use. Notification updates publish fresh tokens.
        actions[key] = actions[key].orEmpty().filterNot { it.token == token }
        return runCatching { current.actionIntent.send(); true }.getOrDefault(false)
    }
    // Render the application icon (including adaptive drawables), never message
    // avatars or notification photos. The bounded PNG fits inside a wire frame.
    private fun applicationIcon(packageName: String): String = runCatching {
        val drawable = packageManager.getApplicationIcon(packageName)
        val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        try {
            drawable.setBounds(0, 0, 96, 96)
            drawable.draw(Canvas(bitmap))
            val output = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            val bytes = output.toByteArray()
            check(bytes.size <= 48_000)
            Base64.encodeToString(bytes, Base64.NO_WRAP)
        } finally { bitmap.recycle() }
    }.getOrDefault("")

    @Synchronized private fun publish(item: StatusBarNotification) {
        if (item.packageName == packageName || item.notification.flags and Notification.FLAG_ONGOING_EVENT != 0 ||
            item.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val prefs = getSharedPreferences("bridge", MODE_PRIVATE)
        val observed = prefs.getStringSet("observedApps", emptySet()).orEmpty().toMutableSet()
        if (observed.add(item.packageName)) prefs.edit().putStringSet("observedApps", observed).apply()
        val service = BridgeService.instance ?: return
        if (prefs.getStringSet("excludedApps", emptySet()).orEmpty().contains(item.packageName)) {
            actions.remove(item.key)
            service.send(Message("notificationRemoved", payload("key" to item.key)))
            return
        }
        if (!service.mirrorEnabled) return
        val app = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(item.packageName, 0)).toString() }.getOrDefault(item.packageName)
        val extras = item.notification.extras
        val exposed = if (service.previewsEnabled) item.notification.actions.orEmpty().filter { eligible(it) || (service.notificationRepliesSupported && replyInput(it) != null) }.take(3)
            .map { ExposedAction(UUID.randomUUID().toString(), it, item.postTime) } else emptyList()
        actions.remove(item.key); actions[item.key] = exposed
        while (actions.size > 100) actions.remove(actions.keys.first())
        val descriptors = JSONArray(exposed.map {
            val input = replyInput(it.action)
            payload("id" to it.token, "title" to it.action.title.toString().take(80), "kind" to if (input != null) "reply" else "action",
                "placeholder" to (input?.label?.toString()?.take(80) ?: "Reply"))
        })
        service.send(Message("notification", payload("key" to item.key.take(512), "app" to app.take(100),
            "package" to item.packageName, "appIconPNG" to applicationIcon(item.packageName), "title" to (if (service.previewsEnabled) extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty().take(300) else "New notification"),
            "body" to (if (service.previewsEnabled) (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty().take(2000) else ""),
            "actions" to descriptors)))
    }
}
