# Building Bridge

Run commands from the repository root unless noted. Use a Mac with Xcode command-line tools and the macOS 27 SDK for Mac builds.
The SDK is a build requirement; the app deployment target is macOS 13.0.
Both Intel and Apple Silicon editions are cross-compiled from the same source. Android builds need
JDK 17, SDK platform `android-37` and build tools `36.0.0`.

**Compatibility targets are not runtime certification.** Older macOS versions
(13, 14, 15 and 26), native Intel hardware and the Android 10–17 device matrix
remain untested for this update. See [the compatibility status](COMPATIBILITY.md).

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

By default, both architectures build:

| Edition | App bundle | Installer |
| --- | --- | --- |
| Apple Silicon (`arm64`) | `dist/macos/AppleSilicon/Bridge.app` | `dist/Bridge-AppleSilicon.dmg` |
| Intel (`x86_64`) | `dist/macos/Intel/Bridge.app` | `dist/Bridge-Intel.dmg` |

Each installer contains `Bridge.app` for dragging into Applications. Both editions
use the same application identity, feature set and external settings/pairing data.
Choose the edition through Apple menu → About This Mac: an Intel processor needs
Intel; an Apple M-series chip needs Apple Silicon.

`package-mac.sh` builds both editions unless `BRIDGE_SKIP_BUILD=1` is set. It
validates architectures, the macOS 13 minimum, extension versions, App Intents,
icons, signatures and DMGs. Each DMG is mounted read-only, compared with the
signed source app and unmounted before writing SHA-256 sidecars. Mac packaging keeps the
other edition and historical installers; it does not run platform-wide cleanup.
For one edition, set `BRIDGE_MAC_ARCH=arm64` or `BRIDGE_MAC_ARCH=x86_64` for both
build and package commands. The default is `all`.

To verify bundle replacement/rollback in temporary directories:

```sh
python3 scripts/test-installer.py dist/macos/AppleSilicon/Bridge.app
python3 scripts/test-installer.py dist/macos/Intel/Bridge.app
```

See [COMPATIBILITY.md](COMPATIBILITY.md) for runtime and hardware acceptance.
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

This uses the checked-in wrapper, runs release JVM tests and lint, assembles the release
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

Run `scripts/test-mac.sh` and Android's `:app:testReleaseUnitTest` and
`:app:lintRelease` after relevant changes. `BRIDGE_MAC_TEST_ARCH=x86_64` selects
Intel test binaries; running them on Apple Silicon requires an already installed
Rosetta runtime and does not replace native Intel acceptance. To run native UI
checks, build `scripts/build-polish-qa.sh` and run `.build/polish-qa-cli --checks`. Once both packages exist, `python3 scripts/verify-final-build.py` checks
current 1.0 versions, manifests and absence of mirroring. The installer regression
script requires a built Mac app and uses temporary destinations.

Use the acceptance checklist for real-device pairing, reconnects, file integrity,
notification permissions/actions, clipboard restrictions and cancellation. Historical
checks do not establish physical-device reliability or a fresh-clone Android build.
