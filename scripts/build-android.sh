#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ -z "${JAVA_HOME:-}" ]]; then
  if [[ -x /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java ]]; then
    export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  elif [[ -x /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java ]]; then
    export JAVA_HOME=/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  else
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  fi
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$JAVA_HOME/bin:$PATH"
mkdir -p "$ROOT/dist"
cd "$ROOT/android"
./gradlew --no-daemon "$@" :app:testReleaseUnitTest :app:lintRelease :app:assembleRelease
APK=app/build/outputs/apk/release/app-release.apk
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify "$APK"
"$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 4 "$APK"
python3 - "$APK" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as apk:
    dex = b''.join(apk.read(name) for name in apk.namelist() if name.endswith('.dex'))
    if b'com/google/mlkit/vision/codescanner/GmsBarcodeScanning' not in dex:
        raise SystemExit('Build rejected: Google stock QR scanner is missing')
    if b'com/journeyapps/barcodescanner/ScanContract' in dex:
        raise SystemExit('Build rejected: obsolete ZXing scanner is still bundled')
print('Verified Google stock QR scanner')
PY
cp "$APK" "$ROOT/dist/Bridge.apk"
VERSION=$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' app/build.gradle.kts)
cp "$ROOT/dist/Bridge.apk" "$ROOT/dist/Bridge-$VERSION.apk"
shasum -a 256 "$ROOT/dist/Bridge-$VERSION.apk" > "$ROOT/dist/Bridge-$VERSION.apk.sha256"
python3 "$ROOT/scripts/clean-old-releases.py" "$ROOT/dist/Bridge-$VERSION.apk"
echo "Built $ROOT/dist/Bridge.apk (non-debuggable release; locally configured signing key)"
if [[ "$*" == *":notification-test:assembleDebug"* ]]; then
  cp notification-test/build/outputs/apk/debug/notification-test-debug.apk "$ROOT/dist/BridgeNotificationTest.apk"
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify "$ROOT/dist/BridgeNotificationTest.apk"
  echo "Built $ROOT/dist/BridgeNotificationTest.apk (separate diagnostic app)"
fi
