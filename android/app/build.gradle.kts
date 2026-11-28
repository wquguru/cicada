plugins { id("com.android.application") }

val appVersion = rootProject.file("../VERSION").readText().trim()
val appVersionCode = appVersion.split(".").map { it.toInt() }.let { (a, b, c) -> a * 10000 + b * 100 + c }

val releaseKeystore = System.getenv("CICADA_KEYSTORE")?.let { file(it) }?.takeIf { it.isFile }

android {
    namespace = "com.wquguru.cicada"
    compileSdk = 36
    ndkVersion = "29.0.14206865"
    defaultConfig {
        applicationId = "com.wquguru.cicada"
        minSdk = 29
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersion
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }
    externalNativeBuild { ndkBuild { path = file("src/main/jni/Android.mk") } }
    androidResources { noCompress += "bin" }
    signingConfigs {
        if (releaseKeystore != null) create("release") {
            storeFile = releaseKeystore
            storePassword = System.getenv("CICADA_KEYSTORE_PASSWORD")
            keyPassword = System.getenv("CICADA_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("CICADA_KEY_ALIAS") ?: "cicada"
        }
    }
    buildTypes {
        debug { applicationIdSuffix = ".dev"; versionNameSuffix = "-dev" }
        release {
            isMinifyEnabled = false
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildFeatures { buildConfig = true }
    sourceSets {
        getByName("main") {
            assets.directories.add(layout.buildDirectory.dir("generated/strings").get().asFile.path)
            assets.directories.add(layout.buildDirectory.dir("generated/voiceprint").get().asFile.path)
        }
    }
}
kotlin { jvmToolchain(21) }

dependencies { implementation(project(":core")) }

val copyStrings by tasks.registering(Sync::class) {
    into(layout.buildDirectory.dir("generated/strings/Resources"))
    for (lang in listOf("zh-Hans", "en", "ja", "ko")) {
        from(rootProject.file("../Resources/$lang.lproj")) { include("Localizable.strings", "Localizable.stringsdict"); into("$lang.lproj") }
        from(file("src/main/strings/$lang.lproj")) { include("Android.strings"); into("$lang.lproj") }
    }
}
val copyVoiceprint by tasks.registering(Sync::class) {
    from(rootProject.file("../linux/models")) { include("voiceprint.bin") }
    into(layout.buildDirectory.dir("generated/voiceprint"))
}
tasks.named("preBuild") { dependsOn(copyStrings, copyVoiceprint) }
