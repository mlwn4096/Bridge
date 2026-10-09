# Bridge icons

The Mac application uses the named `BridgeAppIcon` app-icon set in `Assets.car`, plus a complete standalone `BridgeLauncherIcon.icns`. Info.plist declares both CFBundleIconName and CFBundleIconFile. The catalog is produced by Apple’s actool from the cobalt/white BridgeAppIcon.png at all ten standard macOS 1x/2x resolutions. Packaging validates the actual CoreUI catalog renditions; merely finding an ICNS file is insufficient for notification identity validation.

`scripts/build-mac-icons.py` generates the catalog from the existing launcher asset and compiles it. `scripts/draw-mac-app-icon.swift` renders that launcher asset. The DMG volume uses the companion ICNS. Existing phone notification artwork, Android icons and monochrome menu-bar mark remain separate.

BridgeApp.init assigns NSApplication.applicationIconImage before constructing BridgeModel. Before initializing UserNotifications, the running app registers its current bundle through Launch Services. The installer replaces the complete app, verifies its signature, touches it and refreshes Launch Services registration. These changes preserve the bundle ID, pairing and notification permission identity. Existing delivered banners can retain their old appearance; test a new banner after installation.

Apple reference: [Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon), [CFBundleIconName](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname).

Build 19 was visually reported unsuccessful. Build 20 fixes startup ordering. Existing cached sender icons may require toggling only Bridge’s Allow Notifications off/on after installing and opening the updated app. A fresh banner is required to confirm resolution.

Build 21 preserves actool’s catalog and additionally packages a complete eleven-representation standalone ICNS through 1024px. CFBundleIconFile, runtime assignment and DMG volume use BridgeLauncherIcon.icns. Validation requires all eleven PNG chunks and independently decodes the fallback. The reduced actool companion must not be used as the sole standalone fallback.
