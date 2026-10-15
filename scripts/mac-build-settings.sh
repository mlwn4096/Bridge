#!/bin/zsh
# Shared by build, metadata, packaging and compatibility checks.
BRIDGE_MAC_MIN_VERSION=13.0

bridge_mac_select_arch() {
  case "$1" in
    arm64) BRIDGE_MAC_LABEL=AppleSilicon ;;
    x86_64) BRIDGE_MAC_LABEL=Intel ;;
    *) print -u2 'Expected arm64 or x86_64'; return 1 ;;
  esac
  BRIDGE_MAC_TARGET="$1-apple-macos$BRIDGE_MAC_MIN_VERSION"
  BRIDGE_MAC_APP="$ROOT/dist/macos/$BRIDGE_MAC_LABEL/Bridge.app"
  BRIDGE_MAC_STATE="$ROOT/.build/macos/$BRIDGE_MAC_LABEL"
}

bridge_mac_architectures() {
  case "${BRIDGE_MAC_ARCH:-all}" in
    all) print -l arm64 x86_64 ;;
    arm64|x86_64) print -r -- "$BRIDGE_MAC_ARCH" ;;
    *) print -u2 'BRIDGE_MAC_ARCH must be all, arm64 or x86_64'; return 1 ;;
  esac
}
