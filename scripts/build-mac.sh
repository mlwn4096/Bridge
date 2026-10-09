#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$ROOT/.build/module-cache" "$ROOT/dist/Bridge.app/Contents/MacOS" "$ROOT/dist/Bridge.app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos27.0 \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT"/mac/Sources/*.swift -o "$ROOT/dist/Bridge.app/Contents/MacOS/Bridge"
cp "$ROOT/mac/Info.plist" "$ROOT/dist/Bridge.app/Contents/Info.plist"
cp "$ROOT/mac/Resources/BridgeIcon.png" "$ROOT/dist/Bridge.app/Contents/Resources/BridgeNotification.png"
cp "$ROOT/mac/Resources/BridgeMenuIcon.png" "$ROOT/dist/Bridge.app/Contents/Resources/BridgeMenuIcon.png"
# macOS volumes commonly ignore case: "bridge" would overwrite "Bridge".
mkdir -p "$ROOT/dist/Bridge.app/Contents/Resources/Tools"
rm -f "$ROOT/dist/Bridge.app/Contents/MacOS/bridge-cli"
cp "$ROOT/scripts/bridge" "$ROOT/dist/Bridge.app/Contents/Resources/Tools/bridge-cli"
"$ROOT/scripts/build-intents.sh"
EXTENSION="$ROOT/dist/Bridge.app/Contents/PlugIns/BridgeShare.appex"
mkdir -p "$EXTENSION/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos27.0 \
  -module-name BridgeShare -application-extension \
  -module-cache-path "$ROOT/.build/module-cache" -parse-as-library \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "$ROOT/mac/ShareExtension/ShareViewController.swift" \
  -o "$EXTENSION/Contents/MacOS/BridgeShare"
cp "$ROOT/mac/ShareExtension/Info.plist" "$EXTENSION/Contents/Info.plist"
rm -f "$ROOT/dist/Bridge.app/Contents/Resources/Bridge.icns"
# Notification identity must include the named CoreUI app icon, not only a
# Finder-readable ICNS. actool emits both Assets.car and the native ICNS.
python3 "$ROOT/scripts/build-mac-icons.py" "$ROOT/dist/Bridge.app/Contents/Resources"
# A stable certificate keeps Keychain trust across rebuilds. Set this to the
# exact identity name from security find-identity -v -p codesigning.
SIGNING_IDENTITY="${BRIDGE_SIGNING_IDENTITY:--}"
python3 "$ROOT/scripts/verify-mac-bundle.py" "$ROOT/dist/Bridge.app"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --entitlements "$ROOT/mac/ShareExtension/Entitlements.plist" --sign - "$EXTENSION"
  codesign --force --sign - "$ROOT/dist/Bridge.app"
else
  codesign --force --options runtime --timestamp --entitlements "$ROOT/mac/ShareExtension/Entitlements.plist" --sign "$SIGNING_IDENTITY" "$EXTENSION"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$ROOT/dist/Bridge.app"
fi
codesign --verify --deep --strict "$ROOT/dist/Bridge.app"
echo "Built $ROOT/dist/Bridge.app"
