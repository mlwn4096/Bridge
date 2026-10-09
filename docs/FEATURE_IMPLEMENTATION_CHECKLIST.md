> Historical final-build notes. Paths to `final build/`, personal signing identities and cached offline builds describe the private pre-publication workspace. Use [BUILDING.md](BUILDING.md) for this repository. These notes are not fresh-clone verification.

# Bridge feature implementation and acceptance checklist

Owner: MLWN. Updated: October 8, 2026.

## Working agreement

Implement the features below in order. Only one feature enters manual acceptance at a time. After its build is ready, the owner tests it, reports bugs, and the implementation is corrected and retested until the owner accepts it. Do not begin the next feature until that acceptance. “Tests pass” and “accepted on hardware” are separate statuses; no feature is described as perfect or bug-free based on compilation alone.

Use the existing local authenticated, certificate-pinned connection and preserve pairing, update signing identity, file queues, clipboard privacy, notification exclusions, and current UI. New permissions are requested when their feature is enabled. Optional functionality defaults off. No automatic sending of replies, opening of links, or injection of Mac input.

Record additional confirmed defects, fixes and validation in `FINAL_BUILD_BUG_AUDIT_2026-10-08.md`. Update this checklist after each manual acceptance.

## Baseline before feature 1

- [x] Read the final-build bug audit and trace both transfer directions.
- [x] Preserve queued transfers on receiver failures; retry with a bounded attempt count.
- [x] Make notification Disconnect persist until explicit Connect.
- [x] Replace the entire Mac app bundle and roll back failed installation verification.
- [x] Give the Mac app and DMG their own cobalt Bridge logo and validate all icon sizes.
- [x] Rebuild both release candidates and verify actual packaged payloads.
- [x] Owner confirms Finder/Applications icon after installing the replacement.
- [ ] Owner confirms the notification app icon on a new banner after build 21.

## 1 — Reply to notifications from Mac

Status: implemented and candidate verified; awaiting owner manual acceptance.

Goal: type a reply on Mac for a currently mirrored Android notification that exposes a supported text reply action.

Implementation:

- [x] Negotiate notification-reply support so older versions retain current behavior.
- [x] Android recognizes an eligible free-form RemoteInput action backed by a mutable broadcast/service PendingIntent, with no required authentication or ambiguous input fields.
- [x] Preserve existing non-reply actions; expose a reply action separately with a bounded label and placeholder.
- [x] Require notification sharing, content previews, an unlocked phone, a currently active notification, and an app that is not excluded.
- [x] Bind each reply to a fresh single-use action token. Reject removed, changed, expired or already-used tokens.
- [x] Mac Reply opens an explicit composer identifying the app and notification; Cancel sends nothing.
- [x] Validate nonblank text and a 4096-byte UTF-8 limit at both endpoints.
- [x] Send through Android RemoteInput and the owning app’s PendingIntent. No background retry of messages.
- [x] Return “handed to phone app” versus rejected/unknown feedback. Do not claim delivery to the conversation.
- [x] Disable sending when disconnected or when the action changes; discard temporary composer text when closed.
- [x] Add regression checks for validation, token replay/expiry, queue preservation and ordinary notification actions.
- [x] Build and package both platforms.

Owner’s acceptance checklist:

- [ ] Update both apps without losing pairing.
- [ ] Enable notification access on Android and notification previews on Mac.
- [ ] Receive a message with a native Android Reply action. Open Notifications on Mac, click Reply, type and Send; confirm the reply in the conversation on the phone.
- [ ] Cancel a reply and confirm nothing was sent.
- [ ] Test multiline text, emoji, whitespace-only input, and the byte limit.
- [ ] Remove/update a notification while its composer is open; the old reply must be blocked.
- [ ] Lock the phone, exclude that app, disable previews, disconnect, and unpair in separate tests; sending must be blocked or rejected without deferred delivery.
- [ ] A second click or lost result must not cause automatic duplicate sending.
- [ ] Existing notification dismissal, normal action buttons and app icons still work.
- [ ] File transfer, clipboard, links, ring phone, background reconnect and app update still work.
- [ ] Report defects; fixes rebuilt and retested.
- [ ] Owner explicitly accepts feature 1 before feature 2 starts.

Limits: supports one free-form text RemoteInput. Choices-only, data-only, immutable, activity-launch and authentication-required actions are not exposed. Apps/Android may still refuse the action. Native Mac banner inline replies can be evaluated later; the first implementation uses the Bridge notification list.

## 2 — Recent photos and screenshots

Status: not started; blocked on feature 1 acceptance.

Goal: browse recent accessible photos/screenshots on Mac and request selected items through the existing verified transfer pipeline.

- [ ] Add an Android setting to enable recent media access; default off.
- [ ] Request the appropriate image permission on each supported Android version. Respect selected-photo access and denied/revoked grants.
- [ ] Query a bounded, paginated MediaStore list. Recognize screenshots with provider metadata without assuming one OEM folder name.
- [ ] Show capture date, thumbnail, type and size; label the scope when only selected photos are available.
- [ ] Use session-bound opaque media tokens, not remote arbitrary filesystem paths.
- [ ] Bound thumbnail count, size and cache; refresh without losing navigation.
- [ ] Download only on explicit selection; handle edited/deleted images and provider errors.
- [ ] Send the original readable bytes through existing size/hash/receipt validation.
- [ ] Add permission, pagination, revoked-token and transfer regressions; build both apps.
- [ ] Owner tests a newly taken screenshot, camera photo, selected-photo grant, denial, revocation, deleted media, large collection, Wi-Fi/USB and disconnect during download.
- [ ] Fix reported defects and get explicit acceptance before feature 3.

## 3 — Open links on the other device

Status: existing explicit HTTP(S) handoff; enhancement after feature 2 acceptance.

- [ ] Review current Send link on Android, Mac link command, link cards and click-to-open behavior.
- [ ] Make sending a link clearly discoverable on both platforms with a destination label.
- [ ] Preserve explicit click-to-open on the receiver and existing sensitive-link confirmation.
- [ ] Keep credential-bearing/unsupported URLs rejected; do not queue links across disconnects.
- [ ] Improve success/failure feedback and link-card expiry without transferring browser accounts or sessions.
- [ ] Test article URLs, maps web links, escaped characters, invalid schemes, disconnect and expired cards.
- [ ] Owner verifies handoff in both directions and accepts before feature 4.

## 4 — Find my phone

Status: existing ring command and menu action; polish after feature 3 acceptance.

- [ ] Verify one-click menu action, stop control, current ring state and timeout.
- [ ] Use the paired device’s display name consistently rather than hard-coded Pixel labels.
- [ ] Preserve existing volume/OS limitations and default-off flashlight option.
- [ ] Show a clear disconnected state; never replay a ring command after reconnect.
- [ ] Confirm stopping/disconnecting restores any audio state altered by the feature.
- [ ] Owner tests locked phone, silent mode/DND, timeout, Stop, disconnect and flashlight denial.
- [ ] Fix defects and get acceptance before feature 5.

## 5 — Optional battery percentage in the Mac menu bar

Status: battery metadata, charging state and low-battery alert already exist; menu-bar percentage not started.

- [ ] Add Settings → Battery → Show phone battery in menu bar, default **off**.
- [ ] Persist the choice; keep the current icon-only menu bar when off.
- [ ] When on and connected, show percentage and a compact charging indicator beside the Bridge mark.
- [ ] Hide unavailable/stale percentage when disconnected; no misleading 0% fallback.
- [ ] Keep low-battery alerts independently configurable; preserve threshold, charging suppression and alert throttling.
- [ ] Test 0/1/99/100%, charging/unplugging, disconnect, unavailable readings, light/dark menu bar and restart persistence.
- [ ] Owner confirms the setting is optional and accepts before feature 6.

## 6 — Phone as a Mac remote

Status: not started; requires all earlier acceptances. Direction is **Android controls Mac**. Existing Mac controls for phone media remain separate.

Implement this feature in smaller acceptance stages:

- [ ] 6A: explicit remote-mode session on both devices, opt-in default off, bounded input rate and clear Stop control.
- [ ] 6B: trackpad move, click, right-click and scroll; request Mac Accessibility only when enabling this stage.
- [ ] 6C: keyboard text and a small allowlist of navigation/modifier keys; release held keys on Stop/disconnect and reject input while Mac is locked.
- [ ] 6D: supported Mac media controls with capability reporting; do not invent unsupported per-app playback state.
- [ ] 6E: presentation previous/next slides using explicit remote mode and documented key mappings.
- [ ] Never enable arbitrary shell commands, screen capture or reintroduce the removed phone-screen mirroring engine.
- [ ] Confirm pairing/revocation, session expiry, input bounds, denied Accessibility and stuck-key recovery.
- [ ] Owner manually accepts each stage before the next; test reconnect, screen lock, unpair, modifier release, pointer bounds, supported media apps and slide software.
- [ ] Final regression run and owner acceptance.

## Release record

For each candidate record: Mac build, Android version code, package checksums, automated test results, unresolved defects, exact manual steps and owner acceptance. Keep the current candidate clearly labelled as requiring device testing until its manual checks pass.

### Feature 1 candidate

Mac build 21 / Android version code 12, version 1.0. Packages: `final build/bridge_1.0.dmg` and `final build/bridge_1.0.apk`. Install with `final build/install.zsh` to replace the complete Mac app and update Android without clearing data. The agent attempted Finder replacement for build 21; macOS refused because Bridge was in use. Installed build remains 20; quit Bridge before updating.

Optional isolated test: `dist/qa/Bridge-Notification-Reply-Test.apk` (`dev.bridge.notificationtest`). Open it on Android, grant its notification permission, and tap Create test notification. In Mac Bridge enable previews, open Notifications, Reply, and Send. Reopen the test app to see “Reply received locally” with the exact text. Its receiver records the test reply on the phone; it does not send to a real messaging account. Create a new notification to test Mark read. Also test a real messaging app before accepting.

Manual acceptance: pending. Features 2–6 remain unstarted.
