#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
mkdir -p .build/ui-polish dist/qa/BridgeUIQA.app/Contents/MacOS
python3 - <<'PY'
s=open('mac/Sources/BridgeApp.swift').read().replace('@main\nstruct BridgeApp', 'struct BridgeApp', 1)
open('.build/ui-polish/BridgeApp.swift', 'w').write(s)
PY
sources=(mac/Sources/*.swift)
sources=(${sources:#mac/Sources/BridgeApp.swift})
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 \
  -module-cache-path .build/module-cache "${sources[@]}" .build/ui-polish/BridgeApp.swift \
  mac/Preview/PolishQA.swift -o dist/qa/BridgeUIQA.app/Contents/MacOS/BridgeUIQA
cat > dist/qa/BridgeUIQA.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.bridge.uiqa</string><key>CFBundleName</key><string>BridgeUIQA</string>
<key>CFBundleExecutable</key><string>BridgeUIQA</string><key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string></dict></plist>
PLIST
codesign --force --sign - dist/qa/BridgeUIQA.app

# CLI rendering runs outside the .app because sandboxed native app startup is unavailable.
cp dist/qa/BridgeUIQA.app/Contents/MacOS/BridgeUIQA .build/polish-qa-cli
codesign --force --sign - .build/polish-qa-cli
