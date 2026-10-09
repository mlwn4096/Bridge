#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$JAVA_HOME/bin:$PATH"
mkdir -p "$ROOT/dist"
cd "$ROOT/android"
./gradlew --no-daemon "$@" :app:testReleaseUnitTest :app:assembleRelease
cp app/build/outputs/apk/release/app-release.apk "$ROOT/dist/Bridge.apk"
VERSION=$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' app/build.gradle.kts)
cp "$ROOT/dist/Bridge.apk" "$ROOT/dist/Bridge-$VERSION.apk"
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify "$ROOT/dist/Bridge.apk"
"$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 4 "$ROOT/dist/Bridge.apk"
shasum -a 256 "$ROOT/dist/Bridge-$VERSION.apk" > "$ROOT/dist/Bridge-$VERSION.apk.sha256"
python3 "$ROOT/scripts/clean-old-releases.py" "$ROOT/dist/Bridge-$VERSION.apk"
echo "Built $ROOT/dist/Bridge.apk (non-debuggable release; locally configured signing key)"
if [[ "$*" == *":notification-test:assembleDebug"* ]]; then
  cp notification-test/build/outputs/apk/debug/notification-test-debug.apk "$ROOT/dist/BridgeNotificationTest.apk"
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify "$ROOT/dist/BridgeNotificationTest.apk"
  echo "Built $ROOT/dist/BridgeNotificationTest.apk (separate diagnostic app)"
fi
