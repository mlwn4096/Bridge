package dev.bridge.companion

import android.content.Context
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiSsid
import android.util.SparseIntArray
import android.os.Build
import kotlinx.coroutines.*
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

/** Owns only the app's local-only hotspot; never changes the user's tethering configuration. */
class DirectHotspot(private val context: Context, private val scope: CoroutineScope) {
    @Volatile var session: DirectSession? = null; private set
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var discovery: DatagramSocket? = null
    private var reader: Job? = null
    fun start(value: DirectSession, state: (String) -> Unit, endpoint: (Pair<String, Int>) -> Unit, failed: (String) -> Unit) {
        if (Build.VERSION.SDK_INT < 36 || Build.VERSION.SDK_INT_FULL < Build.VERSION_CODES_FULL.BAKLAVA_1) {
            failed("Automatic direct setup needs Android 16.1 or later."); return
        }
        check(session == null)
        session = value
        try {
            val socket = DatagramSocket(null).apply { reuseAddress = false; bind(InetSocketAddress(DirectSession.DISCOVERY_PORT)); soTimeout = 1000 }
            discovery = socket
            reader = scope.launch {
                val bytes = ByteArray(1025)
                while (isActive && session === value) {
                    try {
                        val packet = DatagramPacket(bytes, bytes.size); socket.receive(packet)
                        value.endpoint(packet.data.copyOfRange(packet.offset, packet.offset + packet.length), packet.address.hostAddress.orEmpty())?.let(endpoint)
                    } catch (_: SocketTimeoutException) { }
                    catch (error: Exception) { if (session === value && isActive) failed("Direct discovery stopped. End direct mode and try again."); break }
                }
            }
            request(value, SoftApConfiguration.BAND_5GHZ, state, failed)
        } catch (error: Exception) { stop(); failed(error.message ?: "Could not start direct connection") }
    }
    @android.annotation.SuppressLint("MissingPermission")
    private fun request(value: DirectSession, band: Int, state: (String) -> Unit, failed: (String) -> Unit) {
        if ((Build.VERSION.SDK_INT < 36 || Build.VERSION.SDK_INT_FULL < Build.VERSION_CODES_FULL.BAKLAVA_1) || session !== value) return
        try {
            val configuration = SoftApConfiguration.Builder().setWifiSsid(WifiSsid.fromBytes(value.ssid.toByteArray(Charsets.UTF_8)))
                .setPassphrase(value.password, SoftApConfiguration.SECURITY_TYPE_WPA2_PSK)
                .setChannels(SparseIntArray().apply { put(band, 0) }).build()
            context.getSystemService(WifiManager::class.java).startLocalOnlyHotspotWithConfiguration(configuration, context.mainExecutor,
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(valueReservation: WifiManager.LocalOnlyHotspotReservation) {
                        if (session !== value) { valueReservation.close(); return }
                        reservation = valueReservation
                        state("Join ${value.ssid} on your Mac${if (band == SoftApConfiguration.BAND_2GHZ) " · 2.4 GHz fallback" else ""}")
                    }
                    override fun onFailed(reason: Int) {
                        if (session !== value) return
                        if (band == SoftApConfiguration.BAND_5GHZ && reason in listOf(ERROR_NO_CHANNEL, ERROR_GENERIC)) {
                            request(value, SoftApConfiguration.BAND_2GHZ, state, failed)
                        } else { stop(); failed("Hotspot could not start ($reason). Turn off any existing hotspot, then try again.") }
                    }
                    override fun onStopped() { if (session === value) { stop(); failed("Direct hotspot stopped. Reconnect your Mac to its usual Wi-Fi.") } }
                })
        } catch (error: Exception) { stop(); failed(error.message ?: "Hotspot permission or configuration unavailable") }
    }
    fun stop() {
        session = null
        reader?.cancel(); reader = null
        discovery?.close(); discovery = null
        reservation?.close(); reservation = null
    }
}
