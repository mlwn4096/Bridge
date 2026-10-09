# Bridge

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%2B%20Android-blue)](docs/BUILDING.md)

**Keep your Mac and Android phone connected, locally.**

Bridge is a native macOS 27 menu-bar app and a Material You Android companion for local file, clipboard and phone activity sharing. No account or cloud relay is included. This repository contains the source for the final 1.0 build, with experimental screen mirroring excluded. Version: [1.0](docs/RELEASE_1.0.md) on both platforms (Mac build 21; Android version code 12).

## Requirements

- **Mac:** Apple Silicon and macOS 27 or later.
- **Android:** Android 10 or later.
- **Connection:** same Wi-Fi/hotspot, or an authorized USB connection with ADB.
- **Status:** early 1.0 release candidate; physical-device acceptance remains in progress.

## Install and pair

Build from source using [BUILDING.md](docs/BUILDING.md). Packaged downloads, when available, appear in [GitHub Releases](https://github.com/mlwn4096/Bridge/releases).

1. Open your `dist/Bridge-1.0.dmg`, drag Bridge into Applications, quit the previous app and open the replacement. Bridge stays in the menu bar; Activity, Settings, Search and optional Developer windows open on demand without a Dock icon.
2. Install your `dist/Bridge-1.0.apk` over the existing Android app, or use the latest alias `dist/Bridge.apk`. Keep the same Android signing key to preserve update compatibility.
3. Keep the devices on the same Wi-Fi or hotspot. Android first launch shows pairing only. Scan the Mac QR or paste its pairing link, then approve the phone on Mac. Codes expire after five minutes.
4. Grant local-network access where requested. Notification mirroring requires Android notification access; sideloaded apps may require **Allow restricted settings** in Android App settings first. Mac banners require macOS notification permission.

After pairing, Android exposes **Send, Activity, Settings**. Optional permissions follow pairing. Closing a Mac window keeps the connection running; Quit stops Bridge. Both apps respect system light/dark appearance. Android uses wallpaper colors on Android 12+, with a fallback palette on Android 10–11.

## Included features


- **Files and folders:** up to 16 GiB per file, 100 queued outgoing items and three concurrent transfers. Folders become ZIP archives; Android selects folders through the system document-tree picker. Queues survive disconnects and restarts; pause, retry and remove controls are available. Interrupted attempts restart at byte zero, with automatic retries and a pause after three failed attempts. Completion requires exact size, SHA-256 verification and a receiver receipt. Mac references original selected files and keeps owned imported files/folder archives durably; Android prepares app-private snapshots. Preparation requires time and disk space. Unpair revokes pending work and prevents an old pairing epoch from reviving queued transfers.
- **Receiving:** Mac saves into Downloads/Bridge, preserving existing names, or asks for a location when configured. Android files below decimal 1 GB save through MediaStore to Downloads/FromMac; larger files require a document-picker destination. Temporary destinations are cleaned after cancellation/recovery. A bounded completion ledger prevents duplicate saves when a final receipt is lost.
- **Sharing:** Android share sheet, Mac Share extension, Services and Finder file/link drop target. Folder ZIP support is implemented on both platforms. Unsupported drag formats still require choosing files explicitly.
- **Clipboard:** text up to 32 KB, explicit phone sending, optional automatic Mac sending and one-time sensitive-text confirmation. Android background reads remain restricted by the OS. Text is never queued offline. Optional history on both platforms stays in memory, excludes heuristically sensitive text, caps entries at 100 and expires unpinned entries after 24 hours. Pins do not survive process exit; disabling history clears it.
- **Notifications and phone controls:** notification previews default off, per-app exclusions, dismissal and supported single-use non-reply actions; battery/charging/Battery Saver, low-battery alerts, ringing, optional default-off flashlight, last-connected phone information and supported phone media-session controls. Supported free-form notification replies are available from the Mac notification list with previews enabled and the phone unlocked; phone-app acceptance does not establish message delivery. Android may redact sensitive content; protected notifications and actions can reject requests.
- **Links:** explicit HTTP(S) handoff, optional title and a ten-minute Mac card. Received files and links open only after a click. Browser scroll position, logged-in sessions and document state are not transferred.
- **Local search and commands:** native Mac filters for retained filenames, notifications, opt-in clipboard history and the current link. No file-content scan, phone-wide index or search database. Five deterministic command phrases show a preview and require Execute: send files, copy to phone, ring phone, pause queue, resume queue. This is not an AI assistant.
- **Automation:** seven native AppIntents, six App Shortcuts, local CLI and opt-in Mac event rules. Rules can show a notification or run a selected installed Shortcut on connection, disconnection, received file or low battery. Cooldowns and execution bounds apply. Shortcuts can perform their own actions according to their configuration.
- **Optional USB developer tools:** authorized USB device listing, device information, packages, bounded recent logcat, screenshots, explicit APK installation and constrained `/sdcard/` listing/download. No dependency installation, arbitrary shell, root or wireless-debugging setup is performed.

ADB reverse forwarding can carry the normal pinned TLS protocol over an authorized USB phone. Wi-Fi fallback remains available; actual throughput depends on the cable, network, ADB and storage. Reboot/force-stop and vendor battery policies can require opening Android Bridge again; there is no boot receiver.

## Repository layout

```text
android/                  Kotlin/Compose companion and Gradle wrapper
  app/                    Production Android application and JVM tests
  notification-test/      Separate diagnostic app for notification testing
mac/                      Native Swift/AppKit/SwiftUI application
  Sources/                App, connection state, protocol, UI and features
  Tests/                  Protocol, automation, archive and artwork checks
  ShareExtension/         macOS Share extension
  Resources/              App, menu and notification artwork
  Preview/                Developer UI rendering tools
scripts/                  Build, packaging, verification and CLI tools
docs/                     Architecture, build guide and release validation
```

Start with [architecture](docs/ARCHITECTURE.md) and [building](docs/BUILDING.md).
The installers, private signing keys, dependency caches, old drafts and experimental
screen-mirroring code are deliberately outside this repository. This is source for
the final app, not a claim that the existing binaries are reproducible byte for byte.

## Build and distribution

The Mac build requires Apple Silicon, the macOS 27 SDK and Swift command-line tools.
Android requires JDK 17, Android SDK platform 37 and build tools 36.0.0. The checked-in
Gradle wrapper pins Gradle 9.6.0; AGP is 9.4.1, Compose compiler 2.2.10 and Compose BOM
2026.09.00. First builds require network access to resolve dependencies.

```sh
chmod +x scripts/*.sh scripts/*.zsh android/gradlew
./scripts/test-mac.sh
./scripts/build-mac.sh
./scripts/package-mac.sh
./scripts/build-android.sh
```

The Android script runs on macOS; on Linux or Windows use the Gradle wrapper directly
as described in [BUILDING.md](docs/BUILDING.md). Output is written to ignored `dist/`
and platform build directories. Installers belong in GitHub Releases, not source commits.

Mac builds are ad-hoc signed by default. Set `BRIDGE_SIGNING_IDENTITY` to your own
installed Developer ID identity and optionally `BRIDGE_NOTARY_PROFILE` to your own
notarytool profile. Android builds use your local debug key unless distribution-key
environment variables are provided. A new key cannot update an installed app signed
with a different certificate. Never commit keys or passwords. See the build guide.

The bundled CLI is `Bridge.app/Contents/Resources/Tools/bridge-cli` and requires Python 3. Normal commands include `devices`, `send`, `clipboard`, `link`, `ring`, `transfers`, and transfer-ID `pause`, `resume`, `cancel`. Developer commands require `--developer-tools`; APK installation also requires `--confirm-install`. CLI installation through Homebrew is not provided.

## Privacy and troubleshooting

Pairing pins the Mac TLS certificate and enrolls a random phone credential after explicit Mac approval. Mac stores an owner-only salted credential verifier; legacy Keychain pairings migrate with at most one explicit unlock. Reconnects do not read Keychain. Android pairing uses Keystore-backed encryption. Unpair revokes trust and associated pending transfers. Metadata-only receipt history is bounded to 500 entries/seven days; clipboard text and credentials do not enter it. See [protocol](docs/PROTOCOL.md).

No telemetry/cloud backend is included. Local automation is off until configured.

For connection problems, check local-network permission, firewall, Wi-Fi isolation and whether both apps are running. Address override retains certificate pinning. Changed certificates require fresh pairing. Queued source files that moved or changed must be selected again; paused failures can be retried or removed. Do not disable certificate validation.

See [verification status](docs/VERIFICATION.md) and [acceptance checklist](docs/FEATURE_IMPLEMENTATION_CHECKLIST.md). Compilation and artifact checks do not establish physical-device reliability. New queue, automation, extension, Shortcuts, search and developer workflows still require device acceptance.

## Contributing and licensing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development and review expectations.
See [PUBLISHING.md](PUBLISHING.md) for repository setup, licensing choices and release
steps. Bridge source is licensed under the [MIT License](LICENSE). You may use,
modify and redistribute it, including commercially, subject to its notice requirements.
See [third-party notices](THIRD_PARTY_NOTICES.md) for dependency obligations.

Report reproducible bugs in [Issues](https://github.com/mlwn4096/Bridge/issues);
for vulnerabilities, follow [SECURITY.md](SECURITY.md).
