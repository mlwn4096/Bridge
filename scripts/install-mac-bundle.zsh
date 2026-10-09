#!/bin/zsh
# Replace a whole bundle on the destination filesystem; roll back failed updates.
set -euo pipefail
SOURCE="${1:?Source app required}"
DESTINATION="${2:?Destination app required}"
PARENT="${DESTINATION:A:h}"
[[ -d "$SOURCE" && -d "$PARENT" && ! -L "$DESTINATION" ]] || { print -u2 "Invalid app installation paths"; exit 1; }
STAGE=$(mktemp -d "$PARENT/.BridgeInstall.XXXXXX")
HAD_PREVIOUS=0
REPLACED=0
COMMITTED=0
cleanup() {
  if (( ! COMMITTED )); then
    if (( REPLACED )); then rm -rf "$DESTINATION"; fi
    if (( HAD_PREVIOUS )); then
      if ! mv "$STAGE/Previous.app" "$DESTINATION"; then
        print -u2 "Could not restore Bridge. Previous app kept at $STAGE/Previous.app"
        return
      fi
    fi
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
ditto --norsrc --noextattr "$SOURCE" "$STAGE/Bridge.app"
codesign --verify --deep --strict "$STAGE/Bridge.app"
if [[ -e "$DESTINATION" ]]; then
  [[ -d "$DESTINATION" ]] || { print -u2 "Destination is not an app directory"; exit 1; }
  mv "$DESTINATION" "$STAGE/Previous.app"
  HAD_PREVIOUS=1
fi
mv "$STAGE/Bridge.app" "$DESTINATION"
REPLACED=1
codesign --verify --deep --strict "$DESTINATION"
touch "$DESTINATION"
COMMITTED=1
