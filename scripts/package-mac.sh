#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ "${BRIDGE_SKIP_BUILD:-0}" != "1" ]]; then "$ROOT/scripts/build-mac.sh"; fi
source "$ROOT/scripts/mac-build-settings.sh"
architectures=("${(@f)$(bridge_mac_architectures)}")
for architecture in "${architectures[@]}"; do
bridge_mac_select_arch "$architecture"
codesign --verify --deep --strict "$BRIDGE_MAC_APP"
python3 "$ROOT/scripts/verify-mac-bundle.py" "$BRIDGE_MAC_APP" --arch "$architecture"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/mac/Info.plist")
STAGE=$(mktemp -d "$ROOT/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$BRIDGE_MAC_APP" "$STAGE/Bridge.app"
codesign --verify --deep --strict "$STAGE/Bridge.app"
python3 "$ROOT/scripts/verify-mac-bundle.py" "$STAGE/Bridge.app" --arch "$architecture"
ln -s /Applications "$STAGE/Applications"
cp "$BRIDGE_MAC_APP/Contents/Resources/BridgeLauncherIcon.icns" "$STAGE/.VolumeIcon.icns"
xcrun SetFile -a C "$STAGE" 2>/dev/null || true
cat > "$STAGE/Install Bridge.txt" <<EOF
Drag Bridge.app into Applications, then open Bridge from Applications.
This is the $BRIDGE_MAC_LABEL edition, requiring macOS 13 or later on supported hardware.
Use About This Mac to check your processor. Intel Macs need Bridge-Intel.dmg;
M-series Macs need Bridge-AppleSilicon.dmg. Both editions have the same features.
Bridge runs in the menu bar, without a Dock icon. On first launch, a Welcome
window helps you download the Android companion. Already installed? Choose
Connect your phone to continue to pairing. Click the menu-bar icon to use Bridge.
Allow local network access when prompted.

Install Bridge on Android. Choose Already installed on the download screen,
scan the Mac pairing code, and approve the phone on your Mac. The phone's main
app appears after pairing is approved.
Both devices need the same Wi-Fi, phone hotspot, or configured USB link.

To update: quit Bridge, replace it in Applications with the newer version,
then reopen it. Pairing and settings live outside the app bundle.

The command-line companion is inside Bridge.app/Contents/Resources/Tools/bridge-cli.
Find Bridge actions in the macOS Shortcuts app after opening Bridge once.
Enable Send with Bridge in System Settings > General > Login Items &
Extensions > Sharing if it does not appear in Finder's Share menu.

This personal release candidate is ad-hoc signed, not Apple Developer ID notarized.
EOF
if [[ -f "$ROOT/docs/RELEASE_$VERSION.md" ]]; then
  cp "$ROOT/docs/RELEASE_$VERSION.md" "$STAGE/Release Notes.md"
elif [[ -f "$ROOT/docs/RELEASE_0.2.0.md" ]]; then
  cp "$ROOT/docs/RELEASE_0.2.0.md" "$STAGE/Release Notes.md"
fi
DMG="$ROOT/dist/Bridge-$BRIDGE_MAC_LABEL.dmg"
USED_HYBRID=0
if ! hdiutil create -volname "Bridge" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; then
  # HFS hybrid creation does not need a temporary mounted disk device.
  HYBRID="$ROOT/.build/Bridge-$BRIDGE_MAC_LABEL-hybrid.dmg"
  hdiutil makehybrid -hfs -hfs-volume-name "Bridge" -ov -o "$HYBRID" "$STAGE"
  # makehybrid invents nonzero Finder icon-location bytes for every entry.
  # Remove those catalog fields, proving every signed payload byte is intact.
  python3 "$ROOT/scripts/check-hfs-app.py" clean "$HYBRID" "$STAGE/Bridge.app"
  python3 "$ROOT/scripts/check-hfs-app.py" verify "$HYBRID" "$STAGE/Bridge.app"
  USED_HYBRID=1
  hdiutil convert "$HYBRID" -format UDZO -ov -o "$DMG"
  rm -f "$HYBRID"
fi
if [[ "${BRIDGE_SIGNING_IDENTITY:--}" != "-" ]]; then
  codesign --force --timestamp --sign "$BRIDGE_SIGNING_IDENTITY" "$DMG"
fi
# Optional: configure a notarytool keychain profile before release.
if [[ -n "${BRIDGE_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$BRIDGE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
python3 "$ROOT/scripts/verify-mac-dmg.py" "$DMG" "$BRIDGE_MAC_APP" --arch "$architecture"
if [[ "$USED_HYBRID" == "1" ]]; then
  # Inspect the actual compressed distribution artifact, not only its input.
  hdiutil convert "$DMG" -format UDTO -ov -o "$STAGE/inspection"
  python3 "$ROOT/scripts/check-hfs-app.py" verify "$STAGE/inspection.cdr" "$STAGE/Bridge.app" --extract "$STAGE/Verified.app"
  codesign --verify --deep --strict "$STAGE/Verified.app"
fi
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Packaged $DMG"
rm -rf "$STAGE"
trap - EXIT
done
