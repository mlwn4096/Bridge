#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/module-cache" "$ROOT/.build/test-state"
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/mac/Sources/Wire.swift" "$ROOT/mac/Sources/SecureIdentity.swift" "$ROOT/mac/Sources/PairingTrust.swift" "$ROOT/mac/Sources/OutgoingQueue.swift" "$ROOT/mac/Sources/TransferReceipts.swift" "$ROOT/mac/Sources/ClipboardProtection.swift" "$ROOT/mac/Sources/BatteryAlerts.swift" "$ROOT/mac/Sources/ClipboardHistory.swift" "$ROOT/mac/Sources/TransferTelemetry.swift" "$ROOT/mac/Sources/LinkHandoff.swift" "$ROOT/mac/Sources/ShareManifest.swift" \
  "$ROOT/mac/Tests/ProtocolTests.swift" -o "$ROOT/.build/protocol-tests"
"$ROOT/.build/protocol-tests" "$ROOT/.build/test-state"

xcrun swiftc -swift-version 5 -parse-as-library -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/mac/Sources/Wire.swift" "$ROOT/mac/Sources/BridgeLocalDeviceInfo.swift" \
  "$ROOT/mac/Sources/BridgeNotificationArtwork.swift" "$ROOT/mac/Sources/NotificationReply.swift" "$ROOT/mac/Tests/NotificationArtworkTests.swift" \
  -o "$ROOT/.build/notification-artwork-tests"
"$ROOT/.build/notification-artwork-tests"
