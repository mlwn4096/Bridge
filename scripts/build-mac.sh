#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
SDK="$(xcrun --show-sdk-path)"
source "$ROOT/scripts/mac-build-settings.sh"
architectures=("${(@f)$(bridge_mac_architectures)}")
for architecture in "${architectures[@]}"; do
bridge_mac_select_arch "$architecture"
mkdir -p "$ROOT/.build/module-cache" "$BRIDGE_MAC_APP/Contents/MacOS" "$BRIDGE_MAC_APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target $BRIDGE_MAC_TARGET \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT"/mac/Sources/*.swift -o "$BRIDGE_MAC_APP/Contents/MacOS/Bridge"
cp "$ROOT/mac/Info.plist" "$BRIDGE_MAC_APP/Contents/Info.plist"
cp "$ROOT/mac/Resources/BridgeIcon.png" "$BRIDGE_MAC_APP/Contents/Resources/BridgeNotification.png"
cp "$ROOT/mac/Resources/BridgeMenuIcon.png" "$BRIDGE_MAC_APP/Contents/Resources/BridgeMenuIcon.png"
cp "$ROOT/mac/Resources/AndroidDownloadQR.png" "$BRIDGE_MAC_APP/Contents/Resources/AndroidDownloadQR.png"
# macOS volumes commonly ignore case: "bridge" would overwrite "Bridge".
mkdir -p "$BRIDGE_MAC_APP/Contents/Resources/Tools"
rm -f "$BRIDGE_MAC_APP/Contents/MacOS/bridge-cli"
cp "$ROOT/scripts/bridge" "$BRIDGE_MAC_APP/Contents/Resources/Tools/bridge-cli"
"$ROOT/scripts/build-intents.sh" "$architecture"
EXTENSION="$BRIDGE_MAC_APP/Contents/PlugIns/BridgeShare.appex"
mkdir -p "$EXTENSION/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target $BRIDGE_MAC_TARGET \
  -module-name BridgeShare -application-extension \
  -module-cache-path "$ROOT/.build/module-cache" -parse-as-library \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "$ROOT/mac/ShareExtension/ShareViewController.swift" \
  -o "$EXTENSION/Contents/MacOS/BridgeShare"
cp "$ROOT/mac/ShareExtension/Info.plist" "$EXTENSION/Contents/Info.plist"
rm -f "$BRIDGE_MAC_APP/Contents/Resources/Bridge.icns"
# Notification identity must include the named CoreUI app icon, not only a
# Finder-readable ICNS. actool emits both Assets.car and the native ICNS.
python3 "$ROOT/scripts/build-mac-icons.py" "$BRIDGE_MAC_APP/Contents/Resources"
# A stable certificate keeps Keychain trust across rebuilds. Set this to the
# exact identity name from security find-identity -v -p codesigning.
SIGNING_IDENTITY="${BRIDGE_SIGNING_IDENTITY:--}"
python3 "$ROOT/scripts/verify-mac-bundle.py" "$BRIDGE_MAC_APP" --arch "$architecture"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --entitlements "$ROOT/mac/ShareExtension/Entitlements.plist" --sign - "$EXTENSION"
  codesign --force --sign - "$BRIDGE_MAC_APP"
else
  codesign --force --options runtime --timestamp --entitlements "$ROOT/mac/ShareExtension/Entitlements.plist" --sign "$SIGNING_IDENTITY" "$EXTENSION"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BRIDGE_MAC_APP"
fi
codesign --verify --deep --strict "$BRIDGE_MAC_APP"
echo "Built $BRIDGE_MAC_APP"
done
