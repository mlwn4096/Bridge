#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TEST_ARCH="${BRIDGE_MAC_TEST_ARCH:-$(uname -m)}"
case "$TEST_ARCH" in arm64|x86_64) ;; *) print -u2 'BRIDGE_MAC_TEST_ARCH must be arm64 or x86_64'; exit 1 ;; esac
TEST_BUILD="$ROOT/.build/tests/$TEST_ARCH"
mkdir -p "$ROOT/.build/module-cache" "$TEST_BUILD/state"
xcrun swiftc -swift-version 5 -parse-as-library -target "$TEST_ARCH-apple-macos13.0" -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/mac/Sources/Wire.swift" "$ROOT/mac/Sources/SecureIdentity.swift" "$ROOT/mac/Sources/PairingTrust.swift" "$ROOT/mac/Sources/OutgoingQueue.swift" "$ROOT/mac/Sources/TransferReceipts.swift" "$ROOT/mac/Sources/ClipboardProtection.swift" "$ROOT/mac/Sources/BatteryAlerts.swift" "$ROOT/mac/Sources/ClipboardHistory.swift" "$ROOT/mac/Sources/TransferTelemetry.swift" "$ROOT/mac/Sources/LinkHandoff.swift" "$ROOT/mac/Sources/ShareManifest.swift" \
  "$ROOT/mac/Sources/DirectTransfer.swift" "$ROOT/mac/Tests/ProtocolTests.swift" -o "$TEST_BUILD/protocol-tests"
"$TEST_BUILD/protocol-tests" "$TEST_BUILD/state"

xcrun swiftc -swift-version 5 -parse-as-library -sdk "$(xcrun --show-sdk-path)" -target $TEST_ARCH-apple-macos13.0 \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/mac/Sources/Wire.swift" "$ROOT/mac/Sources/BridgeLocalDeviceInfo.swift" \
  "$ROOT/mac/Sources/BridgeNotificationArtwork.swift" "$ROOT/mac/Sources/NotificationReply.swift" "$ROOT/mac/Tests/NotificationArtworkTests.swift" \
  -o "$TEST_BUILD/notification-artwork-tests"
"$TEST_BUILD/notification-artwork-tests"
