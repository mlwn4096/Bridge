#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
SDK="$(xcrun --show-sdk-path)"
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
STATE="$ROOT/.build/app-intents"
mkdir -p "$STATE" "$ROOT/dist/Bridge.app/Contents/Resources"
# The compiler expects a protocol-name array; Xcode ships the same list
# wrapped in an object for its build system.
python3 - "$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json" "$STATE/protocols.json" <<'PY'
import json, sys
source = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'w') as output:
    json.dump(source['constValueProtocols'] if isinstance(source, dict) else source, output)
PY
xcrun swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-macos27.0 \
  -module-name Bridge -module-cache-path "$ROOT/.build/module-cache" \
  -whole-module-optimization -typecheck \
  -const-gather-protocols-list "$STATE/protocols.json" \
  -emit-const-values-path "$STATE/Bridge.swiftconstvalues" "$ROOT"/mac/Sources/*.swift
print -rl -- "$ROOT"/mac/Sources/*.swift > "$STATE/sources.list"
print -r -- "$STATE/Bridge.swiftconstvalues" > "$STATE/const-values.list"
xcrun appintentsmetadataprocessor \
  --output "$ROOT/dist/Bridge.app/Contents/Resources" \
  --toolchain-dir "$TOOLCHAIN" --module-name Bridge --sdk-root "$SDK" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 27.0 --target-triple arm64-apple-macos27.0 \
  --source-file-list "$STATE/sources.list" --swift-const-vals-list "$STATE/const-values.list" \
  --app-shortcuts-app-name-override
# Missing metadata would leave a compiled feature invisible to Shortcuts.
python3 - "$ROOT/dist/Bridge.app/Contents/Resources/Metadata.appintents/extract.actionsdata" <<'PYVERIFY'
import json, sys
metadata = json.load(open(sys.argv[1]))
expected = {'RingPhoneIntent', 'StopRingingPhoneIntent', 'SendTextToPhoneIntent', 'SendLinkToPhoneIntent', 'PhoneBatteryIntent', 'PauseSendQueueIntent', 'ResumeSendQueueIntent'}
assert expected <= set(metadata['actions']), 'Missing Bridge App Intents'
assert len(metadata['autoShortcuts']) == 6, 'Missing Bridge App Shortcuts'
PYVERIFY
echo "Built Bridge App Intents and Shortcuts metadata"
