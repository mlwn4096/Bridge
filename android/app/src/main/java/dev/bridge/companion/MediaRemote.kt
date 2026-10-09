package dev.bridge.companion

import android.content.ComponentName
import android.content.Context
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import java.util.UUID

/** Called on the main thread; uses the user's existing notification-listener grant. */
class MediaRemote(private val context: Context, private val send: (Message) -> Unit) {
    private val manager = context.getSystemService(MediaSessionManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val component = ComponentName(context, PhoneNotificationListener::class.java)
    private var controller: MediaController? = null
    private var sessionID = ""
    private var registered = false
    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) { publish() }
        override fun onPlaybackStateChanged(state: PlaybackState?) { refresh() }
        override fun onSessionDestroyed() { refresh() }
    }
    private val listener = MediaSessionManager.OnActiveSessionsChangedListener { refresh() }
    fun refresh() {
        try {
            if (!registered) { manager.addOnActiveSessionsChangedListener(listener, component, handler); registered = true }
            val excluded = context.getSharedPreferences("bridge", Context.MODE_PRIVATE).getStringSet("excludedApps", emptySet()).orEmpty()
            val sessions = manager.getActiveSessions(component).filter { it.packageName !in excluded }
            val next = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: sessions.firstOrNull()
            if (next?.sessionToken != controller?.sessionToken) {
                controller?.unregisterCallback(callback); controller = next
                sessionID = if (next == null) "" else UUID.randomUUID().toString()
                controller?.registerCallback(callback, handler)
            }
            publish()
        } catch (_: SecurityException) { stop(); publish() }
    }
    fun stop() {
        controller?.unregisterCallback(callback); controller = null; sessionID = ""
        if (registered) runCatching { manager.removeOnActiveSessionsChangedListener(listener) }
        registered = false
    }
    private fun supported(): List<String> {
        val actions = controller?.playbackState?.actions ?: 0L
        return listOf("play" to PlaybackState.ACTION_PLAY, "pause" to PlaybackState.ACTION_PAUSE,
            "next" to PlaybackState.ACTION_SKIP_TO_NEXT, "previous" to PlaybackState.ACTION_SKIP_TO_PREVIOUS)
            .filter { actions and it.second != 0L }.map { it.first }
    }
    private fun publish() {
        val current = controller
        send(Message("media", payload("available" to (current != null), "sessionID" to sessionID,
            "title" to current?.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty().take(300),
            "artist" to current?.metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty().take(300),
            "playing" to (current?.playbackState?.state == PlaybackState.STATE_PLAYING),
            "actions" to JSONArray(supported()))))
    }
    fun command(expectedSession: String, action: String) {
        refresh()
        val current = controller
        var accepted = false
        if (current != null && expectedSession == sessionID) {
            accepted = runCatching {
                when (action) {
                    "play" -> { check(action in supported()); current.transportControls.play() }
                    "pause" -> { check(action in supported()); current.transportControls.pause() }
                    "next" -> { check(action in supported()); current.transportControls.skipToNext() }
                    "previous" -> { check(action in supported()); current.transportControls.skipToPrevious() }
                    "volumeUp", "volumeDown" -> context.getSystemService(AudioManager::class.java).adjustStreamVolume(
                        AudioManager.STREAM_MUSIC, if (action == "volumeUp") AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, 0)
                    else -> error("Unknown media command")
                }
                true
            }.getOrDefault(false)
        }
        send(Message("mediaCommandResult", payload("accepted" to accepted)))
    }
}
