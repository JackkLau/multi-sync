import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The local file is intentionally ignored by Git. Android Studio's signed-APK
// wizard can also inject its own signing options without creating this file.
val releaseSigningProperties = Properties().apply {
    val localFile = rootProject.file("keystore.properties")
    if (localFile.isFile) localFile.reader(Charsets.UTF_8).use { load(it) }
}
val releaseSigningValues = mapOf(
    "storeFile" to "MULTISYNC_ANDROID_KEYSTORE",
    "storePassword" to "MULTISYNC_ANDROID_STORE_PASSWORD",
    "keyAlias" to "MULTISYNC_ANDROID_KEY_ALIAS",
    "keyPassword" to "MULTISYNC_ANDROID_KEY_PASSWORD",
).mapValues { (property, environment) ->
    providers.environmentVariable(environment).orNull ?: releaseSigningProperties.getProperty(property)
}
val hasReleaseSigning = releaseSigningValues.values.all { !it.isNullOrEmpty() }
val forceUnsignedRelease = providers.gradleProperty("multisync.unsignedRelease").orNull == "true"
val requireSignedRelease = providers.gradleProperty("multisync.requireReleaseSigning").orNull == "true"
check(!(forceUnsignedRelease && requireSignedRelease)) {
    "不能同时要求发布签名和未签名构建。"
}

android {
    namespace = "local.multisync"
    compileSdk = 35
    defaultConfig {
        applicationId = "local.multisync"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    signingConfigs {
        if (hasReleaseSigning && !forceUnsignedRelease) {
            create("release") {
                storeFile = rootProject.file(releaseSigningValues.getValue("storeFile")!!)
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
                enableV1Signing = false // minSdk 26 supports APK Signature Scheme v2.
                enableV2Signing = true
            }
        }
    }
    buildTypes {
        getByName("release") {
            isDebuggable = false
            signingConfig = signingConfigs.findByName("release")
        }
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging { jniLibs { useLegacyPackaging = false; keepDebugSymbols += "**/*.so" } }
}

val checkReleaseSigning by tasks.registering {
    group = "verification"
    description = "Check that local/env release signing credentials are complete without displaying them."
    doLast {
        check(hasReleaseSigning && !forceUnsignedRelease) {
            "发布签名配置不完整。请配置 apps/android/keystore.properties 或 MULTISYNC_ANDROID_* 环境变量；参见 docs/signing-android.md。"
        }
        check(rootProject.file(releaseSigningValues.getValue("storeFile")!!).isFile) {
            "发布签名密钥库不存在。请检查本地 storeFile / MULTISYNC_ANDROID_KEYSTORE。"
        }
    }
}
dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("com.google.zxing:core:3.5.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

val verifyNativeLibraries by tasks.registering {
    doLast {
        listOf("arm64-v8a", "x86_64").forEach { abi ->
            check(file("src/main/jniLibs/$abi/libmulti_sync_bridge.so").isFile) {
                "缺少 $abi 传输引擎，请先在仓库根目录运行 sh scripts/build-android.sh。"
            }
        }
    }
}
tasks.configureEach {
    if (name == "mergeDebugNativeLibs" || name == "mergeReleaseNativeLibs") dependsOn(verifyNativeLibraries)
    // Only the explicit signed build mode enforces this local/env contract.
    // Android Studio's Generate Signed Bundle / APK wizard remains supported.
    if (name == "preReleaseBuild" && requireSignedRelease) dependsOn(checkReleaseSigning)
}
