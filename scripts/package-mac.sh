#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ "${BRIDGE_SKIP_BUILD:-0}" != "1" ]]; then "$ROOT/scripts/build-mac.sh"; fi
codesign --verify --deep --strict "$ROOT/dist/Bridge.app"
python3 "$ROOT/scripts/verify-mac-bundle.py" "$ROOT/dist/Bridge.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/mac/Info.plist")
STAGE=$(mktemp -d "$ROOT/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$ROOT/dist/Bridge.app" "$STAGE/Bridge.app"
codesign --verify --deep --strict "$STAGE/Bridge.app"
python3 "$ROOT/scripts/verify-mac-bundle.py" "$STAGE/Bridge.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/dist/Bridge.app/Contents/Resources/BridgeLauncherIcon.icns" "$STAGE/.VolumeIcon.icns"
xcrun SetFile -a C "$STAGE" 2>/dev/null || true
cat > "$STAGE/Install Bridge.txt" <<'EOF'
Drag Bridge.app into Applications, then open Bridge from Applications.
Bridge requires an Apple Silicon Mac running macOS 27 or later.
Bridge runs in the menu bar, without a Dock icon or startup window.
Click its bridge icon to pair or use Bridge. Settings and Activity open
only when selected from the menu-bar panel.
Allow local network access when prompted.

Install Bridge on Android. Open it, scan the Mac code, and approve the phone
on your Mac. The phone's main app appears after pairing is approved.
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
DMG="$ROOT/dist/Bridge-$VERSION.dmg"
USED_HYBRID=0
if ! hdiutil create -volname "Bridge" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; then
  # HFS hybrid creation does not need a temporary mounted disk device.
  HYBRID="$STAGE/../Bridge-hybrid.dmg"
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
if [[ "$USED_HYBRID" == "1" ]]; then
  # Inspect the actual compressed distribution artifact, not only its input.
  hdiutil convert "$DMG" -format UDTO -ov -o "$STAGE/inspection"
  python3 "$ROOT/scripts/check-hfs-app.py" verify "$STAGE/inspection.cdr" "$STAGE/Bridge.app" --extract "$STAGE/Verified.app"
  codesign --verify --deep --strict "$STAGE/Verified.app"
fi
shasum -a 256 "$DMG" > "$DMG.sha256"
python3 "$ROOT/scripts/clean-old-releases.py" "$DMG"
echo "Packaged $DMG"
