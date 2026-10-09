# Building Bridge

Run commands from the repository root unless noted. Use an Apple Silicon Mac with
Xcode command-line tools and the macOS 27 SDK for Mac targets. Android builds need
JDK 17, SDK platform `android-37` and build tools `36.0.0`.

## Prepare scripts

If downloaded through a source archive or uploaded through GitHub’s web interface,
restore executable permissions before running the build scripts:

```sh
chmod +x scripts/*.sh scripts/*.zsh android/gradlew
```

## macOS

```sh
xcrun --show-sdk-version
./scripts/test-mac.sh
./scripts/build-mac.sh
./scripts/package-mac.sh
```

The result is `dist/Bridge.app` and `dist/Bridge-1.0.dmg`. `package-mac.sh` builds
the app itself unless `BRIDGE_SKIP_BUILD=1` is set. It validates the signature and
DMG, then writes a SHA-256 sidecar. Packaging removes older platform packages in dist.
The CLI is bundled in `Contents/Resources/Tools/bridge-cli` and requires Python 3.

For Developer ID distribution, set `BRIDGE_SIGNING_IDENTITY` to your installed
certificate name and `BRIDGE_NOTARY_PROFILE` to your configured notarytool profile.
Default signing is ad-hoc and is not notarized. No Apple credentials are provided.

## Android

Install the SDK using Android Studio or Android command-line tools. Set JAVA_HOME
to JDK 17 and ANDROID_HOME to your SDK location. On macOS, for example:

```sh
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
export ANDROID_HOME="$HOME/Library/Android/sdk"
./scripts/build-android.sh
```

This uses the checked-in wrapper, runs release JVM tests, assembles the release
APK, checks signing/alignment and copies it to `dist/Bridge.apk` and
`dist/Bridge-1.0.apk`. Gradle dependencies require Google Maven and Maven Central.
The wrapper downloads its pinned distribution on first use.

On Linux, or on Windows using `gradlew.bat`, run the equivalent Gradle tasks:

```sh
cd android
./gradlew --no-daemon :app:testReleaseUnitTest :app:assembleRelease
```

The result is `android/app/build/outputs/apk/release/app-release.apk`.
For the optional diagnostic app: `./gradlew :notification-test:assembleDebug`.
No personal dependency cache or offline fallback is required or supplied.

### Signing

Development builds use your local Android debug signing key; release builds are
non-debuggable even with that key. For distribution, configure these variables in
your private environment, never in checked-in files:

- `BRIDGE_ANDROID_KEYSTORE`: absolute path to your private keystore.
- `BRIDGE_ANDROID_STORE_PASSWORD`: keystore password.
- `BRIDGE_ANDROID_KEY_ALIAS`: signing alias.
- `BRIDGE_ANDROID_KEY_PASSWORD`: key password.

Keep and back up the same release key for future updates. A differently signed APK
cannot replace the existing installation. Uninstalling removes app data; use a test
device/profile when checking new signing identities.

## Verification

Run `scripts/test-mac.sh` and Android's `:app:testReleaseUnitTest` after relevant
changes. Once both packages exist, `python3 scripts/verify-final-build.py` checks
current 1.0 versions, manifests and absence of mirroring. The installer regression
script requires a built Mac app and uses temporary destinations.

Use the acceptance checklist for real-device pairing, reconnects, file integrity,
notification permissions/actions, clipboard restrictions and cancellation. Historical
checks do not establish physical-device reliability or a fresh-clone Android build.
