# Third-party components

A project license does not replace third-party licenses. Preserve upstream notices.
The Gradle wrapper scripts carry their original Apache-2.0 notices; the wrapper
JAR is included to make builds usable without a global Gradle installation.

Android dependencies are declared in `android/app/build.gradle.kts`: AndroidX
Compose/Activity/Lifecycle/Core, Kotlin coroutines and JourneyApps ZXing Embedded;
JVM tests use JUnit and org.json. Build plugins are declared in the root Android
build file. Review the resolved dependency tree and upstream license texts before
distributing APKs, including transitive components and required attribution.

Mac builds use Apple platform SDKs and tools, which remain under Apple's terms.
ADB is optional, installed separately and not bundled. No scrcpy or mirroring
engine is included. Bridge artwork is in mac/Resources and Android resources;
the maintainer should confirm redistribution rights before the first public release.
This inventory is a starting point, not a completed legal/dependency audit.
