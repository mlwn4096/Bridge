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
        versionCode = 12
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    // Developer builds use the local Android debug key. Public releases may
    // supply a private key using environment variables; never commit keys.
    val releaseKeystore = System.getenv("BRIDGE_ANDROID_KEYSTORE")
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
        getByName("release") {
            // Debug-signed unless a distribution key is explicitly supplied.
            signingConfig = signingConfigs.getByName(if (releaseKeystore.isNullOrBlank()) "debug" else "distribution")
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
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
