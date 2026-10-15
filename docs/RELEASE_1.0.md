# Bridge 1.0 — compatibility release candidate

## October 15, 2026 — Mac build 23 / Android version code 15

- Separate native downloads: **Bridge-Intel.dmg** and **Bridge-AppleSilicon.dmg**.
  Both target macOS 13.0 and retain the same feature set on supported hardware.
  One Android APK retains the Android 10/API 29 minimum.
- Added older macOS API and window fallbacks, protected legacy TLS identity
  loading, native symbol fallbacks and timer scheduling tolerances. No measured
  Intel speed or battery improvement is claimed.
- Android 10–11 retains notification mirroring and dismissal; actions and replies
  require the phone. Android 12+ supports eligible actions/replies and wallpaper
  colors. Configured direct hotspot and promoted notifications require Android
  16.1+; earlier versions retain manual hotspot and standard notifications.
- Verified: both Mac builds, signatures and mounted DMG payloads; 285 Mac checks
  on Apple Silicon and under Rosetta; 38 native UI checks; 67 Android JVM tests;
  Android release build, API compatibility lint, APK signing and alignment.

> **Older OS versions are untested.** This compatibility update has not been
> runtime-tested on macOS 13, 14, 15 or 26, or across Android 10–17 devices/emulators.
> Mac checks ran on macOS 27 with Apple Silicon; Intel checks used Rosetta rather
> than native Intel hardware. End-to-end device workflows and comparative speed
> benchmarks remain pending. Use a prerelease label until device acceptance is
> complete. Mac installers are ad-hoc signed and are not Developer ID notarized.

See [compatibility and remaining checks](COMPATIBILITY.md),
[verification evidence](VERIFICATION.md) and [build instructions](BUILDING.md).

---

The entries below are historical. Paths to `final build/`, personal signing
identities and cached offline builds describe the private pre-publication
workspace and do not supersede the compatibility status above.

## October 10 download onboarding — Mac build 22 / Android version code 13

Fresh, unpaired installations now start with a companion-download step. Mac opens a Welcome window with an Android download QR and button. Android offers the Mac release link and a prewritten email draft. Both have a persisted “Already installed?” action that advances to existing pairing. Paired users bypass this step.

An importable n8n form-to-Gmail workflow prepares automatic one-time download emails. It is not deployed or connected to a sender yet; the shipped APK uses the explicit Gmail/email-app draft fallback. See [download/email setup](DOWNLOAD_ONBOARDING.md).


## October 8 complete launcher-icon follow-up — Mac build 21 / Android version code 12

Restores a complete standalone launcher ICNS (16–1024 pixels) alongside the native app-icon catalog. Finder, the runtime application logo and the DMG volume reference the complete fallback. Packaging now checks every fallback size and decodes the file. Build 20 was reported unsuccessful; notification resolution remains subject to a fresh installed-app banner check. Android is unchanged.

## October 8 notification-icon follow-up — Mac build 20 / Android version code 12

Build 19 still showed the placeholder sender icon in the owner's screenshot. Build 20 loads NSApplication's bundled logo before constructing the notification model, correcting the previous late initialization. The native app-icon catalog remains included. Existing macOS notification identity caches may need Bridge's Allow Notifications switch turned off and back on after installation; test a new banner. Visual resolution is still pending. Android is unchanged.

## October 8 notification-icon follow-up — Mac build 19 / Android version code 12

- User confirmed the Bridge logo appears in the DMG and Applications, but macOS notification banners still show a white placeholder grid. The installed build had no compiled app-icon catalog.
- Mac now includes Apple-compiled Assets.car with the named BridgeAppIcon and all ten 1x/2x icon renditions, plus the compiler’s native ICNS. Info.plist declares CFBundleIconName as well as CFBundleIconFile. The app registers its current bundle before creating its notification-center identity.
- Package verification now checks the actual named CoreUI app icon, not only ICNS existence. Android and notification-reply behavior are unchanged.
- Install the new DMG, quit/reopen Bridge, then Settings → Notifications → Send test notification. Judge the icon on a new banner; existing delivered notifications may retain their previous appearance. Installed-banner verification remains a user test.

## October 8 follow-up — Mac build 18 / Android version code 12

- First staged feature: reply to supported Android notification actions from the Mac Notifications page. Requires both updated apps, notification access, previews enabled and an unlocked phone. Reply → compose → Send; the status confirms handing the reply to the phone app, not delivery to the conversation. Replies are single-use, bounded and never retried. Refresh provides fresh actions.
- Mac app and DMG volume now have a dedicated cobalt Bridge launcher logo, separate from notification artwork. Complete-bundle installation with rollback prevents obsolete icon/resources invalidating the updated app; Launch Services is refreshed after replacement.
- Fixed receiver-side file failures removing the sender’s durable queued item. Updated peers retry and pause after three failures; older peers pause for explicit retry.
- Android notification Disconnect now persists. File preparation continues through transient network disconnects while still bound to the same pairing. Raw file share inputs are restricted to internal folder staging; normal content-provider sharing is preserved.
- This candidate is for feature 1 manual acceptance. Remaining feature work waits for owner acceptance; battery percentage in the menu bar is planned as an opt-in, default-off setting.
- Checklist: docs/FEATURE_IMPLEMENTATION_CHECKLIST.md. Audit and regression record: docs/FINAL_BUILD_BUG_AUDIT_2026-10-08.md.
- Device validation remains required: installed Finder icon/cache, real Android RemoteInput acceptance, receiver disk/provider failures and background preparation/reconnect. No claim of zero bugs is made.

## October 8 update — Mac build 17 / Android version code 11

- Safari-style Mac preference categories and automatic menu-panel dismissal.
- Android sends each notification app’s 96px PNG icon. Mac validates the image and uses it in notification groups and banner attachments. macOS keeps Bridge as the sending application; the source-app image is attachment artwork.
- Phone device details include model, Android version, security update, chip, core count, memory usage, storage usage and battery/charging state.
- The Android Mac card shows battery/charging, storage usage, memory, model, macOS and chip. Desktop Macs show AC power. Snapshots refresh every 15 seconds while authenticated; no serial numbers or accounts are shared.
- Android tab navigation uses short fade/slide transitions. Connection state, storage bars and expanded system details animate subtly.
- Android 16+ requests promoted ongoing connection notifications with Bridge accents; active transfers use native progress styling. A Live connection setting allows opting out. Dismissed live updates are not refreshed again during that connection session. Earlier Android versions retain the standard ongoing notification.
- Verified: production Mac and Android builds; 50 Android unit tests including malformed device info and missing/desktop battery cases; 261 Mac protocol checks plus icon decoding/wire round-trip/local system snapshot checks; package version, signature and payload checks.
- Device checks still required: actual Mac banner image presentation (sandbox attachment test returned “Unrecognized attachment file type”), Android navigation motion and system Live Update promotion. Availability of promoted notifications depends on Android/OEM support and user settings.

## Historical Bridge 1.0 — release candidate for device testing

Mac build 15 · Android version code 10. Installers are in `final build`: `bridge_1.0.dmg` and `bridge_1.0.apk`. These are two separate platform installers. Not published or approved as production-stable yet.

## Changes

- Removed screen mirroring, remote input, mirror engine setup/download, Mac mirror windows/navigation, developer preview/audio/camera modes and CLI mirror commands. Removed the Android accessibility pointer service, its setup UI and the mirroring bind receiver. Historical experimental sources are archived outside production source roots and are excluded from both apps.
- New cobalt icon with a white bridge arch and deck. Consistent Mac app, template menu-bar, Android adaptive/themed launcher, status and in-app marks.
- Android redesigned with large page titles, grouped settings rows, compact permissions, clearer connection controls and expandable privacy, app-sharing and connection details. Inspired by Android's documented settings patterns and Essentials by sameerasw; no verified Android 18 Settings UI was available.
- System, Light and Dark theme preferences persist locally. AMOLED black is an optional pure-black page background in dark appearance; cards retain subtle contrast. Wallpaper-derived accents remain available.
- Send keeps files prominent and groups clipboard/text actions. Long received clipboard previews expand fully. Activity offers All/In progress/Finished filters and keyed lazy rows, with concise empty states and wrapped actions. Main content is capped at 640 dp for larger windows. Cancelled/finished transfers avoid empty action rows.
- Mac temporary feedback counts its eight-second expiry from the moment the message is set, avoiding extra delay when the main actor is busy.

## Preserved

Pair-first onboarding, same-device update identity, TLS certificate pinning, pairing approval, notification exclusions, optional memory-only clipboard history and secret detection, transfer integrity verification, bounded queues/receipts, pause/retry/cancel behavior, folder ZIPs, Find phone, Mac Share extension/Shortcuts/CLI/automations and explicitly authorized USB developer tools. Turning off clipboard history still clears it; unpinned history expires after 24 hours and all history ends with the process.

## Verification

- Both production apps compiled from current source. Android used the cached-dependency offline build because network/Gradle socket access is restricted; application Kotlin and resources were rebuilt, while unchanged library DEX was reused.
- 261 Mac protocol/security/transfer checks; 47 Android JVM tests including appearance preference migration/system behavior.
- 19 Mac UI behavior checks, including replacement-safe feedback expiration, notification labels, automation preference preservation and unauthorized USB state.
- Mac native UI component rendering at 720/1200 points in light/dark appearance, plus empty/disconnected, long text, narrow transfer, filtering and resizing cases. 56 PNGs in `dist/qa/polish`. Cancelled rows measured 65 points at both 440 and 900 points wide. Screens are offscreen components, not a live window test.
- Installer integrity, strict Mac bundle signature, Android v3 signature/16 KiB alignment, release metadata, non-debuggable flag and removal of mirrored-screen code/manifest components checked against real packages.
- Mac is ad-hoc signed, not Developer ID notarized. Android retains the existing personal-install signing key.

## Test before posting

ADB cannot start its server in this sandbox (`Operation not permitted`). Android rendered-screen inspection, install/update, device-specific font scaling, AMOLED on the actual screen, reconnect/background behavior, notification permission and file transfers on actual hardware are outstanding. Do not treat compilation and unit checks as proof of production stability.

1. Install over both current apps without clearing data. Confirm existing pairing survives and both show 1.0.
2. Verify pairing-only first launch on a separate clean test device/profile; scan and approve on Mac.
3. On Android test System/Light/Dark, enable AMOLED, restart and check persistence. Check Send, Activity, Settings, dialogs and keyboard in narrow/landscape layouts and at larger font sizes.
4. Send a photo/document and folder ZIP in both directions. Disconnect/reconnect mid-transfer; pause/retry/cancel and reopen received files. Check large-file save selection and retained retry state.
5. Share clipboard, links and notifications. Verify history disable clears entries, sensitive text needs consent and excluded apps stay excluded.
6. Confirm no Phone Control menu/window/CLI mode or Android pointer-accessibility service remains. Normal notification sharing remains available.

Design references: https://developer.android.com/design/ui/mobile/guides/patterns/settings and https://github.com/sameerasw/essentials.

## Installer repair (2026-10-06)

The first mounted DMG failed strict code-signature verification because the sandbox fallback `hdiutil makehybrid` generated nonzero Finder metadata in all 23 app catalog entries, including the Share extension. The original signed bundle was clean. Packaging now clears only the app’s Finder catalog fields and compares all 11 signed payload files and executable permissions with the clean source. After compression it decompresses the actual DMG, checks metadata and payload again, extracts the bundle and runs strict signature verification. The installer uses a private metadata-free copy and verifies the existing signature before updating Applications; it does not re-sign the app or disable Gatekeeper. The macOS 27 hdiutil deprecation warning is informational; DiskManagement is unavailable in this build environment. Actual mounted installation remains a user-device check. Android bytes/version are unchanged.

## Device, settings and support update (2026-10-07)

- The Send to Pixel drag destination appears only while the phone has an authenticated connection. Disconnecting dismisses it, and drop acceptance rechecks the connection.
- The Mac activity/settings window explicitly supports native fullscreen and resizes its split-view content to the available area. Search, Send files and connection status have separate circular toolbar controls, with the status indicator at the outer right. Gray indicates disconnected; green indicates connected.
- Settings uses native category navigation and grouped controls. Support is a separate sidebar page. Bug and feature forms require a full name, email and description, support five optional images, and differ in icon, guidance and additional fields. Both open an email draft to the configured support inbox; the recipient is hidden on Bridge’s pages but visible in the mail app. Sending is performed by the user. Mac can also save a local draft.
- Support includes Buy me a coffee and About the creator, opening https://buymeacoffee.com/mlwn and https://mlwn.in. Android Settings includes the same support actions and forms.
- The Mac Device page shows the phone model, Android version, free space and a used/total storage bar. Android Settings shows the same local device details.
- Android Settings → Phone files allows choosing or revoking a shared folder. The Mac Device page browses that folder and its subfolders and downloads individual files through the existing verified transfer pipeline. It supports both Wi-Fi and configured USB connections. It does not require ADB or broad storage permissions. Only document tokens enumerated within the selected folder can be requested; tokens are cleared on disconnect and access is checked again for each download. Android’s folder picker determines which folders may be granted.
- Mac notification/app icon now uses a white phone and Bridge mark on the cobalt tile. Android notification icons use white-only transparent phone vectors; the connected state adds radio waves. The installer refreshes Launch Services after replacing the Mac app to update cached notification identity.

Validation for this update: both production sources compiled; 261 Mac protocol checks, 47 Android JVM tests and 19 Mac UI behavior checks passed. Native component views were rendered at 720/1200 points in light/dark appearance, including the new Device and Support pages. Live Mac fixture windows were inspected for Settings and Transfers. Real-phone folder browsing/download, email attachment delivery, OS notification icon cache refresh and installed-app fullscreen transitions still need a device check after installation.

To install both updates without clearing app data:

```sh
zsh "./install.zsh"
```

After installation, choose a shared folder on Android, then open Mac Device → Browse phone files. To submit a support request, finish the form, choose Continue in Mail, review the draft and send it in the mail app.

## Support-style settings and usability review update (2026-10-07)

Mac build 15 · Android version code 10. Settings now uses Support-style grouped cards. The sidebar search field above Device searches settings inline, including help text, automation rules and support; the separate Search & Commands window is removed. The menu panel has four large labeled quick actions and no Activity button.

Mac notification content now carries a bundled phone PNG attachment in both ordinary and mirrored banners. Default notification clicks open Notifications without clearing the source phone notification; explicit dismissal remains separate. The leading app icon remains controlled by macOS.

Review-driven changes include pre-pairing Support, folder Back/breadcrumb navigation, requested-folder refresh/loading guards, clearer Android shared-folder state and connection actions, flashlight permission completion, full clipboard-history expansion, retained support drafts/attachment grants and required-field guidance. The UI/UX, macOS and Android reviewers fed into an independent final judge; see UX Review.md for their scope and resolutions.

Verification: both release builds compiled; 261 Mac protocol, 47 Android JVM and 19 UI checks passed. Mac settings queries/empty results, normal pages and labeled menu renders were inspected. Real-device validation limits remain listed in UX Review.md.
