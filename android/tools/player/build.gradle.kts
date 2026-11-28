plugins { id("com.android.application") }
android {
    namespace = "com.wquguru.cicada.player"
    compileSdk = 36
    defaultConfig { applicationId = "com.wquguru.cicada.player"; minSdk = 29; targetSdk = 36; versionCode = 1; versionName = "1" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(21) }
