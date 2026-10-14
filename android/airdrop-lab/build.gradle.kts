plugins { id("com.android.application") }
android {
    namespace = "dev.bridge.airdroplab"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "dev.bridge.airdroplab"
        minSdk = 31
        targetSdk = 37
        versionCode = 1
        versionName = "0.1"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
