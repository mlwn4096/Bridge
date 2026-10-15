#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
SDK="$(xcrun --show-sdk-path)"
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
source "$ROOT/scripts/mac-build-settings.sh"
bridge_mac_select_arch "${1:-$(uname -m)}"
STATE="$BRIDGE_MAC_STATE/app-intents"
mkdir -p "$STATE" "$BRIDGE_MAC_APP/Contents/Resources"
# The compiler expects a protocol-name array; Xcode ships the same list
# wrapped in an object for its build system.
python3 - "$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json" "$STATE/protocols.json" <<'PY'
import json, sys
source = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'w') as output:
    json.dump(source['constValueProtocols'] if isinstance(source, dict) else source, output)
PY
xcrun swiftc -swift-version 5 -sdk "$SDK" -target $BRIDGE_MAC_TARGET \
  -module-name Bridge -module-cache-path "$ROOT/.build/module-cache" \
  -whole-module-optimization -typecheck \
  -const-gather-protocols-list "$STATE/protocols.json" \
  -emit-const-values-path "$STATE/Bridge.swiftconstvalues" "$ROOT"/mac/Sources/*.swift
print -rl -- "$ROOT"/mac/Sources/*.swift > "$STATE/sources.list"
print -r -- "$STATE/Bridge.swiftconstvalues" > "$STATE/const-values.list"
xcrun appintentsmetadataprocessor \
  --output "$BRIDGE_MAC_APP/Contents/Resources" \
  --toolchain-dir "$TOOLCHAIN" --module-name Bridge --sdk-root "$SDK" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target "$BRIDGE_MAC_MIN_VERSION" --target-triple $BRIDGE_MAC_TARGET \
  --source-file-list "$STATE/sources.list" --swift-const-vals-list "$STATE/const-values.list" \
  --app-shortcuts-app-name-override
# Missing metadata would leave a compiled feature invisible to Shortcuts.
python3 - "$BRIDGE_MAC_APP/Contents/Resources/Metadata.appintents/extract.actionsdata" <<'PYVERIFY'
import json, sys
metadata = json.load(open(sys.argv[1]))
expected = {'RingPhoneIntent', 'StopRingingPhoneIntent', 'SendTextToPhoneIntent', 'SendLinkToPhoneIntent', 'PhoneBatteryIntent', 'PauseSendQueueIntent', 'ResumeSendQueueIntent'}
assert expected <= set(metadata['actions']), 'Missing Bridge App Intents'
assert len(metadata['autoShortcuts']) == 6, 'Missing Bridge App Shortcuts'
PYVERIFY
echo "Built Bridge App Intents and Shortcuts metadata"
