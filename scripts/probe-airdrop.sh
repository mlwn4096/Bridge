#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/airdrop" "$ROOT/.build/module-cache"
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/experiments/airdrop/AirDropProbe.swift" -o "$ROOT/.build/airdrop/probe"
exec "$ROOT/.build/airdrop/probe" "$@"
