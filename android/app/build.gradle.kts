plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "dev.bridge.companion"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "dev.bridge.companion"
        minSdk = 29
        targetSdk = 37
        versionCode = 15
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    // Preserve existing personal-build update identity when available. Public releases may
    // supply a private key using environment variables; never commit keys.
    val releaseKeystore = System.getenv("BRIDGE_ANDROID_KEYSTORE")
    val localBridgeKeystore = rootProject.file("../../private-workspace/.tooling/gradle/android-signing.jks")
    if (localBridgeKeystore.isFile) {
        signingConfigs {
            create("localBridge") {
                storeFile = localBridgeKeystore
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }
    if (!releaseKeystore.isNullOrBlank()) {
        signingConfigs {
            create("distribution") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("BRIDGE_ANDROID_STORE_PASSWORD")
                keyAlias = System.getenv("BRIDGE_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("BRIDGE_ANDROID_KEY_PASSWORD")
            }
        }
    }
    buildFeatures { compose = true }
    buildTypes {
        getByName("debug") {
            if (localBridgeKeystore.isFile) signingConfig = signingConfigs.getByName("localBridge")
        }
        getByName("release") {
            signingConfig = signingConfigs.getByName(if (!releaseKeystore.isNullOrBlank()) "distribution" else if (localBridgeKeystore.isFile) "localBridge" else "debug")
            isDebuggable = false
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    // Play services brings Fragment 1.0.0 transitively; Activity Result requires 1.3+.
    implementation("androidx.fragment:fragment:1.8.9")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
