# Bridge OS compatibility

> **Untested on older operating systems:** this update has not been runtime-tested
> on macOS 13, 14, 15 or 26, or across Android 10–17 devices/emulators. Mac checks
> ran on macOS 27 with Apple Silicon; Intel execution was checked under Rosetta.
> Native Intel hardware, older OS reliability and comparable speeds remain unverified.

## Downloads and targets

| Download | Processor | OS target |
| --- | --- | --- |
| `Bridge-Intel.dmg` | Intel, native x86_64 | macOS 13–27 where the Mac/OS combination is supported by Apple |
| `Bridge-AppleSilicon.dmg` | Apple Silicon, native arm64 | macOS 13–27 where the Mac/OS combination is supported by Apple |
| `Bridge-1.0.apk` | Android companion | Android 10/API 29 through currently tested Android versions |

There are two Mac downloads, with the same features. Each contains an app named
Bridge.app. Apple menu → About This Mac identifies the processor: “Intel” needs
the Intel edition; “Apple M…” needs Apple Silicon. Supporting an OS does not make
an older Mac capable of installing that OS. Future Android versions need validation.

These are compatibility targets, not a claim that every listed OS has completed
runtime acceptance. The current build machine runs macOS 27 on Apple Silicon.
The Intel build is cross-compiled; a native Intel hardware benchmark is pending.

## Behavior by OS

| Capability | Older OS behavior | Newer OS behavior |
| --- | --- | --- |
| Mac windows | macOS 13–14 explicitly opens AppKit windows hosting the same SwiftUI screens | macOS 15+ uses suppressed SwiftUI window scenes |
| Mac controls and symbols | Native older control styles and cached symbol fallbacks | Available system styles and symbols |
| Mac clipboard permission status | Before macOS 15.4, reports “System managed” and retains normal clipboard checks | Reports the OS-provided access policy |
| Mac TLS identity | macOS 13–14 imports the existing PKCS#12 into an encrypted app-owned temporary keychain | macOS 15+ keeps the import in memory |
| Android appearance | Android 10–11 uses fixed light/dark palettes; AMOLED remains available | Android 12+ supports wallpaper colors |
| Android notifications | Android 10–11 mirrors and dismisses notifications; actions/replies require the phone | Android 12+ exposes supported safe actions/replies |
| Automatic direct hotspot | Below Android 16.1, join a phone hotspot manually or use LAN/USB | Android 16.1+ can configure a local-only hotspot where hardware permits |
| Promoted connection notification | Below Android 16.1, uses the standard foreground-service notification | Requests promoted ongoing presentation where supported |

The legacy TLS fallback retains the existing certificate and fingerprint, never
imports into the login keychain, and deletes its temporary keychain when released.
Its random password stays in process memory. Existing heartbeats and wake handling
unlock the app-owned keychain if needed; a crash can leave an encrypted temporary
file for OS cleanup, without its password. Actual sleep/wake on macOS 13–14 remains
a required device check. TLS pinning, pairing and transfer formats are unchanged.

Both Mac binaries use release optimization. Clipboard, heartbeat and USB timers
allow scheduling tolerance to coalesce wakeups. These changes are not a measured
Intel speed improvement; the same transfer engine remains in both editions.

## Acceptance matrix

| Configuration | Required acceptance |
| --- | --- |
| macOS 13, 14, 15 | Both native architectures on Apple-supported hardware; especially legacy windows, TLS, sharing and Shortcuts |
| macOS 26, 27 | Each architecture the OS supports; newer clipboard permissions, toolbar styles and local-network permission |
| Android 10, 11 / API 29–30 | Transfers, manual hotspot, default notification behavior, no exposed remote actions/replies |
| Android 12–15 / API 31–35 | Dynamic colors, safe actions/replies, notification permission and foreground-service boundaries |
| Android 16.0 / API 36.0 | Standard notifications, manual hotspot; no calls requiring API 36.1 |
| Android 16.1 and 17 / API 36.1–37 | Configured hotspot, promoted notifications, API 37 local-network permission |

For each configuration, check clean installation and update without lost pairing,
settings or queues; pairing rejection and certificate mismatch; bidirectional
zero-byte/small/large/folder transfers with SHA-256 verification; cancel, retry,
disconnect and reconnect; clipboard consent; denied optional permissions;
notification previews, dismissal and eligible interactions; battery, media, ring
and flashlight; share sheets, Services, Shortcuts, automation and authorized USB.
Check menu-bar-only startup after setup, setup dismissal after pairing, window
reopening, sleep/wake, light/dark appearance, large text, keyboard and accessibility.

Use emulators for Android OS coverage and physical hardware for Wi-Fi, USB,
hotspot and background behavior. Do not label an untested configuration verified.

## Performance acceptance

On an Intel Mac and an Apple Silicon Mac, record the before/after build, CPU,
OS, connection type, idle CPU/memory/wakeups and UI responsiveness. Run at least
five identical 32 MiB speed probes and five transfers of the same 1 GiB file per
build on the same hardware/network/storage, excluding warmup. Compare medians
separately for Wi-Fi, manual/configured hotspot and authorized USB where available.
Verify hashes and record preparation, transfer and completion separately.
Investigate a median throughput regression over 10%; hardware-to-hardware results
do not establish a software regression. Native Intel performance and end-to-end
throughput comparisons remain pending until these measurements are recorded.

See [VERIFICATION.md](VERIFICATION.md) for the checks completed in this workspace.
