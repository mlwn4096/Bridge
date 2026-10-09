# Architecture

Bridge has two native applications and no server backend. The Mac is a menu-bar
application; Android is its paired companion. The production source roots are
`mac/Sources` and `android/app/src/main`. The diagnostic Android app is separate.

## Entry points and state

- Mac: `BridgeApp.swift` initializes the app and menu-bar UI. `BridgeModel.swift`
  coordinates pairing, connections, transfers and phone state. `BridgeUI.swift`
  and the feature-specific views render those states.
- Android: `MainActivity.kt` presents pairing and Send/Activity/Settings.
  `BridgeService.kt` maintains the connection and handles protocol work;
  `BridgeState.kt` exposes state to the Compose UI.
- `Wire.swift` and `Wire.kt` implement framing and message handling. Changes here
  need coordinated peer compatibility and tests. See [PROTOCOL.md](PROTOCOL.md).

## Trust and transport

Mac pairing uses SecureIdentity/PairingTrust and the transport layer; Android uses
Pairing. The phone pins the Mac certificate and receives an enrollment credential
after explicit approval. Wi-Fi and authorized USB forwarding carry the same pinned
TLS protocol. USB developer functions are optional and require installed ADB.

## Transfers and feature modules

OutgoingQueue persists pending work; TransferReceipts provides bounded completion
history; FolderArchive packages folders. Android uses OrderedReceivePipeline for
bounded receive work. ClipboardProtection and ClipboardHistory handle sensitive
text and optional memory-only history. NotificationReply/NotificationReplyPolicy
and PhoneNotificationListener enforce notification action and reply constraints.

PhoneFiles exposes only an Android user-selected shared tree. MediaRemote,
PhoneTorch and the corresponding Mac controls provide opt-in device actions.
BridgeAutomation and BridgeIntents implement local rules and macOS Shortcuts.
The ShareExtension writes manifests consumed by BridgeShareReceiver.

## Build model

Mac scripts invoke swiftc directly; there is no Xcode project or Swift package.
The application, extension, icon catalog and CLI are assembled into a signed bundle.
Android uses Gradle and Compose. Generated outputs are ignored. Historical release
checks document earlier observations, not fresh validation of every developer clone.
Screen mirroring is absent from this repository and production entry points.
