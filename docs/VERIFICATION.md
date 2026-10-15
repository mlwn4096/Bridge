> Historical final-build notes. Paths to `final build/`, personal signing identities and cached offline builds describe the private pre-publication workspace. Use [BUILDING.md](BUILDING.md) for this repository. These notes are not fresh-clone verification.

# Verification


## October 15, 2026 — macOS 13 compatibility and processor-specific installers

- Mac build 23 and Android version code 15. The main Mac app and Share extension
  compile as separate optimized arm64 and x86_64 builds, both targeting macOS
  13.0. Plists, Mach-O minimum versions, matching extension versions, seven App
  Intents, six App Shortcuts, native icons and strict ad-hoc signatures verify.
- `dist/Bridge-AppleSilicon.dmg` and `dist/Bridge-Intel.dmg` pass image checksums.
  Each image was mounted read-only; its entire app payload matched the signed
  source bundle, architecture and signature checks passed, and it was unmounted.
  Both temporary-directory installer replacement/rollback suites pass. No change
  to the user's Applications folder was made.
- 285 protocol/TLS checks plus notification-artwork/local-device-snapshot checks
  pass on Apple Silicon and for x86_64 binaries under the installed Rosetta runtime.
  New checks force the legacy private-keychain import on the current OS, preserve
  the certificate fingerprint, sign after lock/unlock and verify temporary cleanup.
  This is not a macOS 13–14 runtime test or a native Intel performance benchmark.
- 38 native UI checks pass on macOS 27, including creating/reusing the legacy
  AppKit-hosted windows without presenting them and fallback system symbols. The
  QA harness now runs AppKit's event loop so hosting native views does not stall
  under dispatchMain. UI checks do not establish older-OS visual/accessibility
  acceptance or real-device setup, Share extension hosting and Shortcuts execution.
- Normal Gradle release compilation, JVM tests and lint passed using the installed
  SDK/caches with dependency access, without the cached-library fallback. 67 JVM
  tests pass; lint reports no errors or NewApi/InlinedApi findings. Existing
  dependency/style warnings remain. APK signature, 16 KiB alignment, Google QR
  scanner inclusion, API 29 minimum and non-debuggable release manifest verify.
- Android 10–11 keeps mirroring/dismissal but requires phone interaction for actions
  and replies, as explicitly selected by the user. Android 12+ advertises replies.
  Configured hotspot and promoted-notification API guards now require API 36.1.
  Tests cover capability boundaries at API 29/30/31/35/36.0/36.1/37.
- Clipboard/heartbeat timer tolerance and USB timer leeway allow idle wakeup
  coalescing. No measured Intel CPU, battery or throughput improvement is claimed.
  Historical installers and existing source work were preserved.
- Pending: native Intel hardware tests; macOS 13/14/15/26 runtime acceptance;
  Android 10–17 emulator/physical-device coverage; pairing/update persistence and
  end-to-end LAN/USB/hotspot transfers; comparative performance benchmarks. No app
  installation, GitHub upload, Developer ID notarization or full OS-matrix
  certification is claimed. See [COMPATIBILITY.md](COMPATIBILITY.md).

## October 10, 2026 — companion download onboarding

- Mac build 22 / Android version code 13. Production apps compile. Mac app/extension versions match; native icon catalog, bundled download QR and strict signatures verify. Compressed DMG extraction matches all 15 signed payload files.
- Android signature and 16 KiB alignment pass; current Kotlin source hashes match the adjacent build report. Kotlin, Compose and application resources are freshly compiled; unchanged cached dependency DEX/resources are reused because online Gradle resolution is unavailable here.
- 271 Mac checks and notification artwork/local snapshot checks pass. 58 Android JVM tests pass, including recipient-list/header-injection rejection and production HTTPS form URL validation.
- Bundled download QR round-trip decodes to the GitHub Releases URL. Light/dark download previews were inspected.
- n8n workflow structure and recipient validator were checked locally. No account/credential exists, so import, production form and live Gmail delivery are not tested. Current APK uses the explicit email-draft fallback.
- First-launch window activation, Android UI/browser/email intents, permissions and actual pairing still need physical-device acceptance. No install or GitHub publication is claimed.


## 0.3.5 — input tuning and files

- Both production apps compile. 261 Mac core, 62 Phone Control, 44 native mirror/input and 44 Android JVM checks pass. New tests cover scroll scaling, HID input/release, keyboard preference restoration and rejection retention/retry across restart.
- Native controls rendered at 360/600 points in light/dark. Live ADB/video/IME/scrolling/file transfer acceptance remains outstanding; video codec round-trip explicitly skipped because the encoder is unavailable (-12908).
- See release changes and validation limits (historical document retained privately).

## 0.3.4 — native mirror and pointer assistance

- Production Mac/Share extension and Android sources/resources compile. 258 core Mac, 61 Phone Control, 32 native mirror and 43 Android JVM checks pass. Native cursor morphing/stale-target/lock/letterbox behavior tested; four native control layouts rendered in narrow/wide light/dark.
- Actual H264 round-trip explicitly skipped: VideoToolbox encoder creation fails with -12908 in this environment. Physical ADB access is blocked; live mirroring, scrolling, Android assistance, Touch ID and cleanup acceptance remain outstanding.
- Installed official 5.0 server digest and packet framing inspected; native integration is pinned to this server. Existing engine fallback retained.
- See setup, privacy and limits (historical document retained privately).

## 0.3.3 — native phone pointer

- Production macOS app and Share extension compile. 61 Phone Control checks pass, including default UHID, Option capture shortcut, correct secondary button bindings, touch fallback and authorized wireless mode.
- Physical-device pointer, hover, capture/release and trackpad acceptance remain outstanding. See release details (historical document retained privately).
- Android is unchanged at 0.3.1; its connected status-bar icon is already included.

## 0.3.2 — macOS UI polish

- Production macOS app and Share extension compile; 258 core, 56 Phone Control and 17 UI behavior checks pass.
- Native offscreen production-component snapshots cover narrow/wide light/dark, scroll/filter/resize, long names/text, empty/disconnected states and disabled controls. Cancelled rows measure 65 points.
- Original live Search inversion was not reproduced offscreen; interactive native inspection failed to start. See QA coverage and limits (historical document retained privately).
- Android remains the unchanged 0.3.1 package.

## 0.3.1 — Phone Control, branding and status indicator

- 258 Mac checks, 56 Phone Control authorization/configuration/diagnostics checks and 43 Android JVM tests pass.
- Current Mac production app/Share extension and Android production Kotlin/Compose/resources compile. Android app R classes are freshly generated from linked resources, with unchanged cached dependency DEX/resources.
- Mac/Android release signatures, Android page alignment, Mac native bundle headers, DMG integrity and SHA-256 checksums verify. Shared icon rendering and alpha transparency were inspected.
- Phone Control engine download and physical ADB interaction cannot be tested in this environment (DNS and ADB socket restrictions). Actual input, hidden display, audio, frame rate, wireless pairing and Android indicator visibility require acceptance on the Pixel. The view is currently an engine-rendered window, with native Bridge setup/session controls. See Phone Control (historical document retained privately).
- Mac remains ad-hoc signed; Android retains the existing personal-install certificate.

## 0.3.0 release — October 5

- Current Mac production app and Share extension compile against macOS 27 for Apple silicon. Native executable headers and deep strict ad-hoc signatures verify. Seven App Intents and six App Shortcuts metadata entries compile. DMG integrity and SHA-256 verify.
- 258 Mac protocol/storage/security checks and 43 Android JVM tests pass, including persistent queues, receipt matching, quarantine/reset and emergency payload pause across restart. Separate folder archive and automation suites previously passed.
- Current Android Kotlin/Compose sources and application resources compile through the cached offline build fallback. Dependency DEX is reused from the successful prior dependency build; this is not a fresh Gradle dependency resolution. APK is non-debuggable, retains the personal install certificate, and passes signature, 16 KiB page alignment and SHA-256 checks. Source hashes are recorded in the adjacent APK build report.
- Old versioned DMG/APK packages and their sidecars were removed only after successful replacement builds.
- No physical-device install, real reconnect/folder transfer, USB developer mode, torch, automation execution, Share extension hosting or Shortcuts execution acceptance is claimed. Mac is ad-hoc signed and not notarized; a Developer ID identity is unavailable.
- The following historical reports describe earlier builds. Current scope and outstanding work are in the 0.3.0 report (historical document retained privately).

## 0.2.0 personal MVP release — October 4

- Mac production app and sandboxed Share extension compile, plists lint and deep ad-hoc signatures verify. App uses version 0.2.0/build 2 and regular Dock activation. DMG checksum verifies.
- Five App Intents and four App Shortcuts are compiled into registered metadata; CLI and Share request validation are included.
- 228 Mac checks pass, including 17 new share-manifest tests; 32 Android JVM tests pass, including ambiguous pairing-link regressions.
- All final Android production Kotlin/Compose sources and current application resources compile. D8 merges production bytecode with unchanged cached dependency DEX; APK is non-debuggable, signed with the prior install certificate, and page alignment verifies. Source hashes/build report are saved beside the APK.
- Native libraries and resources.arsc are stored rather than compressed; library data is aligned to 16 KiB, resource data to four bytes. Runtime class coverage is compared with the prior APK.
- Mac light/dark dashboard and onboarding component previews were inspected; see mac/Preview/README.md for renderer limitations.
- Interactive app inspection timed out. No physical-device install, new lifecycle/large-file regression, Share extension host execution, Shortcuts execution or fresh throughput benchmark is claimed. These remain acceptance tests.
- No Developer ID signing identity was available; Mac is not notarized. Android retains the existing personal certificate for updates.

See release scope and remaining roadmap (historical document retained privately). Historical entries below describe earlier increments and do not supersede this release report.

## Completed locally

- Mac built against the macOS 27.0 SDK for Apple silicon; bundle structure and plist verified.
- Ad-hoc code signature verified with `codesign --verify --deep --strict`.
- 152 Swift checks: framing at every split boundary, Unicode/newlines, consecutive frames, malformed/oversized frames, safe filenames, hash validation, known SHA-256 vector, random credential size, equality checks, TLS identity reload, Network.framework identity creation, and owner-only file permissions.
- Android Gradle build and initial seven JUnit tests passed in the user Terminal; initial APK signature verified using APK Signature Scheme v2.
- Latest Android source compiled independently with the cached Kotlin 2.2.10 and Compose compiler; expanded ten-test JUnit suite passed, including pairing parsing, rejection, and fresh credential generation.
- Final Kotlin changes and adaptive/themed launcher resources passed the user Terminal Gradle build with all ten tests. Final APK signature verified.
- User confirmed that the Mac menu-bar icon works and its pairing QR code appears in the native window.
- User confirmed successful APK installation on the Pixel and QR pairing/approval; both apps show Connected.
- Eleven-test Android pairing/protocol suite includes a regression check for literal `+` characters in Mac pairing tokens.

## Pending

- Automatic Mac receiving into Downloads/Bridge is implemented. Collision/reservation/path validation tests pass; device test and manual-mode toggle remain pending.
- Successful peer Keychain reads are cached per process to avoid repeated reads during reconnect. Actual password-dialog cause and prompt reduction remain unverified; ad-hoc rebuild identity remains a limitation.

- User confirmed clipboard works on Mac and Pixel after the automatic Android-write update. Notifications, Mac-to-Pixel files and ringing were also user-confirmed. Background observation of Android clipboard changes is not implemented.
- New Mac sensitive-text filtering and Sync Once confirmation require device verification.
- Finder drag-and-drop and multi-file selection compile in the signed Mac app. Test one and three files, reject a larger batch, drop a folder and drop while disconnected; verify clear feedback and successful accepted transfers on the Pixel.

- Final APK update for the pairing-token parser regression fix; current paired-device feature tests are in progress.
- Native UI inspection on macOS 27 and physical Pixel.
- Paired-device feature and lifecycle checks below. Connectivity is user-confirmed; clipboard, notifications, file transfer, and ring checks are in progress.

## Device acceptance checklist

1. Start both apps on the same Wi-Fi. Scan QR and approve only on Mac. Pair once, restart apps, and reconnect without enrollment.
2. Reject an expired/incorrect QR token. Reject a certificate mismatch before sending credentials. Unpair either device and confirm the old credential cannot reconnect.
3. Copy Unicode text and multiple lines on Mac with Android Bridge in the background; paste directly into another phone app without tapping a notification. Automatic Android clipboard writes are implemented but awaiting device verification. The previous explicit Copy action worked on the user's Pixel. Share text from Android; verify Mac paste. Confirm no echo loop. Toggle auto-send off. Verify oversized and sensitive Mac clipboard entries are skipped.
4. Grant/deny each permission independently. Clipboard and files must still work without notification access. Check sideloaded restricted-settings onboarding.
5. Post/update/dismiss a test Android notification. Verify generic previews by default, content only after enabling previews, app exclusion, and removal. Verify no ongoing/group-summary duplicates.
6. Transfer zero-byte, small, Unicode-named, and large files in both directions. Compare SHA-256. Decline/cancel mid-transfer; disconnect during transfer; ensure incomplete files are removed. Save/open/export a completed file. Preserve an existing Mac file.
7. Send web links in both directions; confirm they open only on user action. Reject non-web schemes.
8. Observe battery/charging updates. Ring phone, stop from each device, and check 30-second timeout and silent mode.
9. Lock/unlock the Pixel, sleep/wake Mac, switch Wi-Fi/hotspot, deny local network access, and test a guest network with client isolation. Record device-specific background restrictions. After force-stop/reboot, reopen Bridge and reconnect.
10. Mac: click menu-bar icon, use settings/activity windows, test system light/dark and accent colors, reduced transparency, keyboard access, VoiceOver, and reduced motion.
11. Pixel: change wallpaper/system palette, light/dark mode, text size, gesture navigation, and TalkBack. Check that surfaces, buttons, navigation, and system bars remain readable and use the system-derived palette.

Never use a successful compile as evidence that these device scenarios passed.

## Drag-to-Pixel increment

- Mac compiled, ad-hoc signed and verified; 184 Mac checks passed (including bounded history and cancellable hashing).
- Android production Kotlin sources compiled successfully using cached compiler/libraries. Offline JVM WireTest: 12 tests passed, including exact decimal 1 GB auto-receive consent boundary.
- Five independent agent reviews completed; findings addressed. See DRAG_SEND_REVIEW.md.
- Gradle APK build in this session is blocked by local-socket sandbox restriction (FileLockContentionHandler SocketException). Updated APK installation and Finder/Pixel/SAF device tests remain required; existing dist/Bridge.apk is not this update.
- User withdrew request to sleep Mac; no sleep attempted.

- User confirms the drag-to-Pixel flow works and the received file saves in Downloads/FromMac. Large-file consent and interruption edge tests remain pending.

## Binary transport increment

- Mac signed build succeeded; 191 checks passed, including mixed/fragmented binary-control framing, raw NUL/newline/0xff bytes, bounds and negative sequence rejection.
- Android production Kotlin source compilation succeeded; 17 offline JVM tests passed, including maximum binary bodies, short reads, truncated/oversized frames and rejection of JSON-forged binary messages.
- Real network/device interoperability and throughput measurement are pending APK packaging/install and Mac restart. No AirDrop/LocalSend speed claim has been verified.

## Sender metrics and research increment

- Three requested agent investigations completed. User explicitly confirmed not having installed the earlier binary update; previous 5 MB/s measurement cannot establish binary performance.
- Mac build/signature verification passed; 198 checks passed. Android production Kotlin source compiled; 19 offline JVM tests passed, including bounded monotonic rates and ETA validity.
- Sender percentage is receiver-confirmed for negotiated peers, Finishing preserves confirmed progress, final Complete stays gated on verified fileReceived. Android phase update before final message avoids completion-state overwrite.
- Actual APK packaging/device throughput and UI metrics tests remain pending user Terminal build/install and Mac restart.

## Hotspot pipeline follow-up
User reports hotspot approximately 8–9 MB/s and USB 1.5 GB transfer in roughly 10–15 seconds. Both are informal device observations. New four-batch Mac window, private network decoding queue, and bounded Android receive pipeline compile successfully; signed Mac app rebuilt. Existing 198 Mac checks pass. Android offline JUnit now passes 22 tests including FIFO completion ordering, slow-writer backpressure and shutdown/write synchronization. Android full packaging and real hotspot/USB regression tests remain pending user Terminal build/install. No new measured speed gain claimed.

## Android clipboard privacy increment
Ported Mac conservative secret heuristics; sensitive explicit sends require payload-bound, single-use, in-memory consent. Material You confirmation covers phone clipboard, typed text, share text and links. Five new unit tests cover OTP/prose distinction, known key/credential/token formats, whole-value Luhn card checks, consent replay and payload substitution. Offline JVM suite passes 27 tests. No claim that heuristics detect all passwords. Pixel confirmation/share/lifecycle tests and APK packaging remain pending. Wireless tuning paused at user request; current speed accepted for now without certifying the untested pipeline update.

## Drag links and open notifications milestone
Mac signed app build and final Android production source compilation pass. Existing handoff validation/expiry and protocol suites pass: 211 Mac checks, 28 Android offline JVM tests. Native drag callbacks, Pixel notification PendingIntent opening, Mac notification Open categories and shared ClipData streams compile; real browser drag, notification tap and file-open device checks remain pending. Full APK must be packaged in user Terminal; no device success claimed.

## 0.2.3 reconnect authentication

241 Mac checks pass, including verifier persistence across store recreation, wrong/malformed credentials, device binding, independent salts, no serialized raw credential, private file permissions, corrupt-file rejection and revocation. Production app compiles; native bundle, deep ad-hoc signatures and compressed DMG checksums verify. User identified the dev.bridge.mac.peer Keychain prompt. Physical-phone migration/reconnect and dialog behavior remain pending installation. Routine authentication no longer calls Keychain after migration.

## Mac 0.2.4 / Android 0.2.1 visual refresh

The vector app icon was rendered and visually inspected at 1024px; its ICNS representations and matching template menu-bar resource are packaged in the Mac app. Production Mac compilation, 241 checks, native bundle validation, deep ad-hoc signing and DMG verification pass.

Android's redesigned production Compose source and launcher/notification resources compile with the cached offline toolchain. 32 JVM checks pass. APK signature verification, non-debuggable manifest inspection and 16 KiB native-library alignment pass. Pairing-only entry, approved-pairing transition, Send/Activity/Settings navigation, text approval, file cancellation and receive/export controls were reviewed in source. No live Android screenshot or physical-phone interaction test is claimed: ADB failed to bind its server socket under the session restrictions.


## Bridge 1.0 candidate (2026-10-06)

Both source builds passed; 261 Mac core checks, 47 Android JVM tests and 17 Mac UI behavior checks passed. Mac component rendering produced 56 PNGs covering 720/1200-point light/dark screens, empty/disconnected cases and long content/filter/resize/scroll cases. Strict code signing, Android v3 signature and 16 KiB alignment passed. Real package inspection confirmed 1.0 (Mac 13, Android 8), non-debuggable APK, menu-bar mode and absence of native mirror code, CLI mirror mode and Android mirroring/accessibility components. Initial UI timing check failed under concurrent builds; expiry now uses a presentation-time monotonic deadline and a bounded test scheduling allowance, and the 17 checks passed.

Android uses the cached-library fallback build; all application Kotlin/resources were rebuilt. ADB server startup is denied in this sandbox. Android visual/device acceptance, installs/updates, hardware transfers and background reliability remain unverified. Mac rendering is offscreen, not live interaction. Mac ad-hoc signing is not Developer ID notarization. See [RELEASE_1.0.md](RELEASE_1.0.md) for the before-publication test checklist.
