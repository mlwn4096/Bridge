# Direct transfer and speed measurements

Bridge can use an app-owned local-only Android hotspot to bypass a slow router.
This uses Bridge's existing certificate-pinned TLS, pairing credential, binary
file framing and integrity checks. It does not implement Apple AirDrop or AWDL.

Automatic hotspot setup needs Android 16.1/API 36.1 or later and an updated Mac app.
The ordinary LAN and optional USB connections remain available. On older Android
versions, manually connecting the Mac to the phone's regular hotspot still works.

## Try the test build

1. Open the appropriate `dist/macos/AppleSilicon/Bridge.app` or `dist/macos/Intel/Bridge.app` on the Mac and install `dist/Bridge-1.0.apk`
   on the phone. These are local test artifacts, not a published release. Update
   both peers; a previously paired device should not need to pair again. The APK
   uses Bridge's original personal-build signing identity when its local key is
   available, falling back to Android's debug key for new workspaces. If your installed phone build
   has a different signing identity, stop rather than uninstalling and losing data.
2. Connect Bridge normally. With no transfers in progress, run **Check connection
   speed** on the Mac's Transfers page. Record the result.
3. On Android's Send page, tap **Direct transfer** and grant Nearby Wi-Fi access.
   On the Mac's Transfers page, reveal the temporary password and open Wi-Fi
   settings. Join the displayed `Bridge-…` network within two minutes.
4. Wait for **Connected via Direct Wi-Fi**. Run the speed check again, then send
   the same local file to the same local phone destination as the LAN comparison.
5. Once transfers finish, end direct mode and reconnect the Mac to its usual
   Wi-Fi. The hotspot has no internet access and is not the phone's normal
   tethering configuration.

The hotspot requests 5 GHz with automatic channel selection; no-channel/generic
failures retry 2.4 GHz using the same credentials. A fallback is shown on the phone.
Hardware, radio coexistence, regulatory constraints and OEM behavior can still
prevent startup. The physical Pixel 8/Mac sequence and actual speed improvement
have not yet been validated on devices.

## What the measurements mean

**Connection speed check:** the Mac sends 32 MiB of synthetic data over the actual
authenticated TLS/binary path. The Android consumer validates ID, sequence and
length, but neither hashes nor saves this data. The Mac's displayed rate includes
send scheduling, receiving and the final result response. The phone displays its
first-to-last-chunk receive rate; buffered read-ahead can make the two differ.
This is application throughput on that connection, not the Wi-Fi PHY link rate.
The test expires after 45 seconds, reserves both peers against concurrent file
transfers, and never creates a file or completion receipt.

**Completed file timings:** cards show preparation, waiting/acceptance, transfer,
finishing and total elapsed time for the attempt. Sender preparation includes
existing hashing/staging; the live MB/s estimate still excludes preparation and
finishing. Incoming timing starts when receiving begins. Queue dwell and the
Android save-location dialog before acceptance are not part of incoming timing.
Timings are session-memory diagnostics, not a durable history schema change.

Mac logs (`dev.bridge.mac`, category `transfer`) and Android logs (`BridgeTransfer`)
record completed Mac-to-phone transfer size, negotiated encoding, route and phase
times. They omit filenames, file contents, passwords, pairing credentials and
discovery addresses. Both updated peers should report `encoding=binary-v1`.

Compare the Mac's connection-speed result with the file transfer phase rate. A
fast probe but slow file suggests storage/provider, hashing, staging or additional
file-processing overhead. If both are slow, investigate the radio path and transport
processing. A local-only hotspot can also be slower than a good router; no fixed
speed increase is guaranteed.

## Lifecycle and compatibility

- Both endpoints negotiate `directHotspotV1` and `speedProbeV1` during existing
  pairing/authentication. Unsupported peers retain the current transfer protocol.
- Direct setup reserves idle peers before starting the hotspot. Current file
  transfers, outstanding offers, preparation or speed checks prevent route changes.
- The Mac sends hotspot session ID and listener port in small UDP broadcasts on
  local interfaces. It never broadcasts the Wi-Fi password or pairing credential.
  Android accepts bounded private-IPv4 route hints for the current session only;
  hints do not authenticate peers. The existing pinned Mac TLS certificate must
  verify before authentication credentials are sent.
- Direct addresses and hotspot credentials stay in memory and do not replace the
  saved LAN pairing address. Default-network changes do not kill a direct socket;
  loss of the actual socket still triggers normal cleanup/reconnect.
- Setup expires after two minutes. Ending direct mode, unpairing, service shutdown
  or hotspot failure releases the app's hotspot reservation and discovery socket.
  A late hotspot callback after cancellation immediately closes its reservation.
- UDP endpoint changes do not replace an already selected direct connection during
  a transfer. Existing interrupted-file behavior remains restart-from-zero.
- Joining/returning to Wi-Fi is an explicit Mac user action. Bridge does not change
  Wi-Fi settings silently or require private macOS/Android networking APIs.

## Development verification

The Mac application builds and passes 277 protocol/identity/validation checks plus
the notification-artwork/device-snapshot suite. Android passes 64 JVM tests,
including discovery scope/bounds, probe sequence/length enforcement and phase
timings. The complete current Kotlin/Compose source and resources compile.

Normal Gradle startup is blocked by sandbox socket restrictions in this session.
`scripts/build-android-cached.py` rebuilds app sources and resources, reuses matching
dependency DEX/resources from the maintained prior release build and local Gradle
9.6.0 cache, then signs and verifies a separate test APK. It requires those caches
and the local Bridge/debug signing key; it is not a general replacement for Gradle.
`scripts/build-android.sh` remains the normal build command outside this constraint.

Needed device checks: hotspot creation and fallback band, manual Mac join,
UDP discovery and pinned reconnect, no-internet transfer, cancellation/timeout,
return to LAN, USB/LAN compatibility, and probe-versus-file comparisons.
