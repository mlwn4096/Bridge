> Historical final-build notes. Paths to `final build/`, personal signing identities and cached offline builds describe the private pre-publication workspace. Use [BUILDING.md](BUILDING.md) for this repository. These notes are not fresh-clone verification.

# Final build bug audit — October 8, 2026

Current candidate: Mac build 21 / Android version code 12 (version 1.0). This document replaces the original review-only report with the findings, fixes and repeated review record requested by the owner. The original three defects are retained below with their resolved status.

## 1. High — receiver errors removed the sender’s queued transfer — fixed

Original paths: Mac `BridgeModel.failTransfer/cancelTransfer`; Android `BridgeService.failTransfer/cancelTransfer` and both `fileCancel` handlers.

Both receivers previously called cancelTransfer after write, integrity or publication failure. The resulting fileCancel permanently removed the peer’s outgoing journal entry; Android deleted its prepared payload. Reproduction path: make the receiver destination unwritable during a transfer; sender became Cancelled rather than retryable. Original user files were not deleted.

Fix: both platforms advertise `fileFailureV1`. A receiver failure cleans the partial destination locally and sends fileFailed, distinct from user cancellation. The sender retains its durable entry, increments bounded failure/backoff state, and pauses after three attempts. Older peers receive fileReject and retain a paused item for explicit retry. Inactive/late failure IDs are ignored. Mac journal errors disable its queue rather than pretending retry state was saved. Persisted failure counts are clamped to avoid overflow in malformed metadata.

Validation: new queue regression checks exercise all three failures, persistence across reopening, retained source/payload, increasing retry delays, pause at attempt three, and unknown IDs. Production handlers compiled on both platforms. Real receiver disk/provider fault injection remains a manual check.

## 2. Medium — notification Disconnect was undone on Android resume — fixed

Original path: BridgeService ACTION_STOP left `bridge/enabled` true; MainActivity.onResume automatically restarted an absent service.

Fix: explicit ACTION_STOP sets enabled=false before stopping. Involuntary connection loss still preserves the reconnect preference, and in-app Disconnect behavior remains consistent.

Validation: reviewed explicit Stop → preference write → service shutdown → onResume condition. Android production compilation passed. Device check: tap notification Disconnect, wait, reopen Bridge and confirm it stays disconnected until Connect.

## 3. High — installer merged app bundles and could leave invalid installation — fixed

Original path: `final build/install.zsh` used ditto directly over Applications/Bridge.app. Old resources survived and invalidated the replacement signature, without rollback.

Original reproduction: a verified app copy plus obsolete-resource.txt retained that file after the original ditto operation; codesign exited 1 with “a sealed resource is missing or invalid”. All reproduction was in temporary directories.

Fix: `scripts/install-mac-bundle.zsh` stages and verifies a complete new bundle on the destination filesystem, backs up the old bundle, moves the whole replacement into place, verifies it again, then commits. Failure restores the old bundle; a failed restoration preserves its backup with the recovery path. Installer still verifies source checksums/signatures and refreshes Launch Services. The helper is included in final build.

Validation: automated tests run the actual helper against temporary app bundles. Whole replacement removes an obsolete resource and passes strict signature verification. Injected final-verification failure restores the previous bundle and sentinel file. Invalid staging leaves the previous bundle untouched. No staging directories leak. Applications was not modified.

## 4. User-reported — Mac application and notification icon placeholders — Finder resolved; notification sender icon still under verification

The previous app already contained an icon, so the installed Finder cache symptom could not be attributed conclusively to a missing asset. The current candidate has a dedicated `BridgeAppIcon.png`/`BridgeAppIcon.icns` launcher logo (white arch/deck on cobalt), with a new resource name in CFBundleIconFile and the runtime app-icon assignment. Notification artwork remains separate. DMG volume artwork uses the launcher logo. Mac build is incremented to 18; the extension version matches.

Validation: visually inspected the 1024px launcher asset. Packaging verifies all eleven ICNS chunk sizes and PNG dimensions, the plist resource reference, bundle signatures and actual DMG extracted payload bytes. Complete replacement avoids retaining the old icon file; installer touches/registers the app after verification. Owner subsequently confirmed the icon works inside the DMG and Applications. Notification banners still showed the placeholder grid, so the first fix did not resolve the notification-service lookup.

Follow-up for build 19: inspection confirmed the installed app lacked Assets.car and CFBundleIconName. Replaced manual-only icon packaging with Apple actool output (named BridgeAppIcon catalog and native ICNS), declared CFBundleIconName, and register the running bundle before initializing UserNotifications. Packaging now checks all ten standard 1x/2x named CoreUI renditions. This fixes the missing native icon identity resource; whether it clears the existing notification-service cache must be confirmed using a newly generated banner after installing build 19. No notification database/cache deletion or bundle-ID change is used.

## 5. Medium — network disconnect cancelled Android file preparation — fixed in follow-up review

Original path: every connectionLoop finally called cleanupTransfers, which removed all preparing IDs. A large file selected while the Mac was offline could be cancelled by the next failed reconnect even though preparation is an independent peer-bound worker.

Fix: connection cleanup discards incoming partials and resets active outgoing attempts, while preparation continues under the same pairing. Explicit cancel/unpair still removes its ID; service destruction cancels its coroutine scope. Generated folder staging files still clean up in the worker’s finally path.

Validation: traced failed-connect, active-transfer disconnect, explicit cancel, unpair and service destruction paths; Android production compilation passed. Physical-device check remains: queue a large file while offline, let several reconnects fail, then reconnect and verify the prepared file sends.

## 6. High — raw share file URIs could point into Bridge private storage — fixed in follow-up review

Original path: exported MainActivity accepted a share EXTRA_STREAM; BridgeService opened arbitrary file:// paths with Bridge’s own access after the user clicked Send. An external caller could supply a guessed private filename. This required user interaction and was established by source tracing; no private data was read during review.

Fix: outgoing inputs must be content:// picker/provider URIs, or a regular file in an internally prepared `cache/bridge-folder-UUID/` directory. Raw private paths, unsupported URI schemes, traversal and symbolic-link aliases are rejected. Canonical cache-root aliases are accommodated so normal Android cache paths still work. Cleanup uses the same staging restriction.

Validation: added tests accepting a valid internal archive and rejecting an app-private file, a loose cache file, a symlink to private storage and traversal. Existing normal folder and queue tests remain enabled. Android production sources rebuilt after the fix.

## Feature 1 implementation review

Notification reply implementation uses negotiated notificationReplyV1, current action identity/post time, excluded-app/privacy/unlock checks, five-minute monotonic single-use leases, a 4096-byte UTF-8 bound, RemoteInput and explicit Send. Reply results distinguish phone-app invocation from delivery. Transport/result timeout never retries. UI drafts are temporary and discarded on close, disconnect or disabling previews/sharing. Pending commands are bound to the originating connection before main-thread dispatch. Normal notification actions remain separate.

Review corrections before the test build: bound deferred replies to their connection; added Refresh for expired tokens; kept replies out of the ordinary action execution/search path; added lease replay checks; cleared drafts on connection/privacy changes. Native UI state uses the project’s existing ObservableObject approach because SwiftUI’s new State macro plugin could not execute in the restricted build environment.

Implementation follows [Android RemoteInput](https://developer.android.com/reference/android/app/RemoteInput). Unit checks cover text boundaries, Unicode/multiline preservation, blank/NUL rejection, expiry and one-time lease consumption. A separate local-only diagnostic notification APK provides a real mutable RemoteInput action and records the resulting text for the owner’s hardware test. It is not part of the production app.

## Review iterations and verification

1. Original audit: package checksums/signature and existing 261 Mac / 50 Android checks passed; identified defects 1–3.
2. Fixed original findings and app/DMG icon; added receiver-failure queue and installer rollback regressions.
3. Traced reconnect/preparation and share input paths; identified and fixed defects 5–6. Added staging-source regression coverage.
4. Implemented feature 1 under the owner’s one-feature-at-a-time process; reviewed token identity, connection replacement, privacy changes, replay and uncertain delivery.
5. Rebuilt candidates and checked signatures, alignment, metadata, source fingerprints, native UI renders and regression suites. Final results: 271 Mac protocol checks, additional icon/device-info/reply-policy/wire checks, 56 Android JVM tests, 19 native UI behavior checks, native light/dark component renders including the reply composer, and installer replacement/rollback checks all passed. Both production apps compiled. Android signing verification and 16 KiB native-library alignment passed. Final installer checksums, Android source fingerprints/build metadata, final-to-dist artifact equality and installer-helper copies also passed after assembly. The compressed DMG was decompressed and its twelve signed app payload files compared with the verified source; the extracted app passed strict signature verification.

No remaining confirmed defect was found in the reviewed paths after these fixes. This is not a proof that the entire application contains no bugs. The owner explicitly requested manual acceptance of each feature; real devices, providers, OS caches and third-party notification actions remain outside automated validation here. Features 2–6 wait for feature 1 acceptance. See `FEATURE_IMPLEMENTATION_CHECKLIST.md`.

## Outstanding manual checks

- Install over current apps without clearing data; confirm pairing and new Finder/Applications logo.
- Test real-app replies and the local fixture, normal actions, dismissal, icons, locked phone, exclusions, stale notifications, disconnect and uncertain results.
- Exercise receiver disk/provider failures in both directions and explicit cancellation.
- Confirm notification Disconnect persists and large file preparation survives offline reconnects.
- Recheck current clipboard, links, ring, file/folder transfers and background reconnect.

Build 19 follow-up verification: production compilation, all ten named CoreUI icon renditions, native ICNS decoding/visual preview, strict app/extension signatures, whole-bundle replacement and rollback tests passed. DMG verification compared the compressed image’s extracted signed payload with the source and verified its signature. Final package checksums passed. Android remains version code 12 with its previous verified bytes. The owner’s next check is a new notification banner after installing build 19.

## Build 20 — notification sender icon initialization

The owner's Screenshot 2026-10-08 at 10.32.34 PM confirms build 19 still displays the generic grid as the leading sender icon. The right-side notification attachment renders correctly. Build 19 must not be considered a verified resolution of this defect.

Code review found that BridgeModel initializes UserNotifications before applicationDidFinishLaunching assigns NSApplication.applicationIconImage. Build 20 assigns the bundled native icon in BridgeApp.init before constructing BridgeModel. It retains the catalog, ICNS, bundle ID and pairing. This corrects the startup ordering; a persisted macOS sender-icon cache may still require refreshing Bridge's notification permission. Do not reset the notification database or unrelated app permissions.

Validation: production compilation and strict app/extension signature verification passed. All ten named icon renditions passed verification. The Mac suite passed 271 protocol checks plus notification artwork, reply-policy, wire round-trip and local device snapshot checks. The final compressed DMG was decompressed; all 13 signed payload files matched the source and its extracted signature passed. Both final package checksums passed. Android remains version code 12 unchanged.

Live inspection: System Settings also showed the generic grid for Bridge. Only Bridge's notification permission was toggled off/on and restored to enabled, preserving its other preferences. Two older mounted Bridge installers were ejected to remove duplicate mounted identities. The UI automation could not access the running accessory app (timeout), so no fresh installed build-20 banner was generated by the agent.

Status: startup correction implemented and package checks passed; notification issue remains open until the leading icon is visually confirmed on a fresh installed build-20 banner.

## Build 21 — complete standalone application icon

Owner reports continued blank icons, including Applications. Direct Finder inspection during this follow-up showed the cobalt Bridge logo on the installed build 20 in /Applications; the owner's reported failure remains relevant and the notification issue is still open.

Inspection found Apple's compiled companion ICNS contains only four chunks (32, 128 and 256-pixel representations), while larger renditions are only in Assets.car. Builds 19/20 accepted this reduced fallback. Build 21 retains the ten-size native catalog and adds BridgeLauncherIcon.icns with eleven PNG representations spanning 16–1024 pixels, matching the complete standalone approach that previously displayed successfully for the owner in Finder. Info.plist, early runtime assignment and DMG volume now use the complete file. The resource filename changes without changing the bundle ID or pairing.

The verifier now requires every expected ICNS representation and PNG dimension and decodes the file with macOS sips, independently of CoreUI validation. This corrects the weakened fallback validation; it is not proof that macOS's persisted notification icon identity has refreshed. Final visual and package validation pending below.

Build 21 validation: production compilation, strict app/extension signatures, ten CoreUI sizes, all eleven standalone PNG dimensions and macOS image decoding passed. A deliberately removed 1024px chunk was correctly rejected by packaging verification. The compressed DMG's extracted 14 signed files matched the source and the extracted signature passed. Final DMG/APK checksums passed; Android bytes remain unchanged. Finder visually displayed the rebuilt app's Bridge logo.

Installation attempt: Finder refused replacement with “the item Bridge is in use.” The installed app remains verified build 20; no process was force-quit and no installation success is claimed. The owner must quit the running Bridge before installing build 21. Notification appearance remains unverified and open.
