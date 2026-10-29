import java.util.Properties

plugins {
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.android.application)
    id("skip-build-plugin")
}

skip {
}

val supportedABIs = listOf("arm64-v8a", "x86_64")
val verifyNativeLibraries = tasks.register("verifyNativeLibraries") {
    doLast {
        val nativeRoot = rootProject.file("../../.build/android/native/jniLibs")
        for (abi in supportedABIs) {
            for (library in listOf("libmpvui.so", "libmpv.so", "libc++_shared.so")) {
                check(nativeRoot.resolve("$abi/$library").isFile) {
                    "Missing $abi/$library. Run: make build PLATFORM=android"
                }
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyNativeLibraries) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(libs.versions.jvm.get())
    }
}

android {
    namespace = group as String
    testBuildType = providers.gradleProperty("mpvuiTestBuildType").orElse("debug").get()
    // SDK levels are pinned to Android 16 in the example module's Skip/skip.yml.
    compileSdk = libs.versions.android.sdk.compile.get().toInt()
    compileOptions {
        sourceCompatibility = JavaVersion.toVersion(libs.versions.jvm.get())
        targetCompatibility = JavaVersion.toVersion(libs.versions.jvm.get())
    }
    packaging {
        jniLibs {
            keepDebugSymbols.add("**/*.so")
        }
    }

    defaultConfig {
        minSdk = libs.versions.android.sdk.min.get().toInt()
        targetSdk = libs.versions.android.sdk.compile.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += supportedABIs }
        // skip.tools.skip-build-plugin will automatically use Skip.env properties for:
        // applicationId = ANDROID_APPLICATION_ID ?? PRODUCT_BUNDLE_IDENTIFIER
        // versionCode = CURRENT_PROJECT_VERSION
        // versionName = MARKETING_VERSION
    }

    buildFeatures {
        buildConfig = true
    }

    dependenciesInfo {
        // Disables dependency metadata when building APKs.
        includeInApk = false
        // Disables dependency metadata when building Android App Bundles.
        includeInBundle = false
    }

    // default signing configuration tries to load from keystore.properties
    // see: https://skip.dev/docs/deployment/#export-signing
    signingConfigs {
        val keystorePropertiesFile = file("keystore.properties")
        create("release") {
            if (keystorePropertiesFile.isFile) {
                val keystoreProperties = Properties()
                keystoreProperties.load(keystorePropertiesFile.inputStream())
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            } else {
                // when there is no keystore.properties file, fall back to signing with debug config
                keyAlias = signingConfigs.getByName("debug").keyAlias
                keyPassword = signingConfigs.getByName("debug").keyPassword
                storeFile = signingConfigs.getByName("debug").storeFile
                storePassword = signingConfigs.getByName("debug").storePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false // can be set to true for debugging release build, but needs to be false when uploading to store
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (testBuildType == "release") proguardFiles("instrumentation-rules.pro")
        }
    }
}

dependencies {
    androidTestImplementation("io.github.lepips:mpvui:0.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

abstract class PreparePlaybackTestMedia : Sync() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    init { into(outputDirectory) }
}
val preparePlaybackTestMedia = tasks.register<PreparePlaybackTestMedia>("preparePlaybackTestMedia") {
    from(rootProject.file("../../.build/test-media")) {
        include("baseline.mp4", "multitrack.mkv", "audio-pcm-stereo.mka")
    }
    outputDirectory.set(layout.buildDirectory.dir("playback-test-assets"))
}
androidComponents.onVariants { variant ->
    variant.androidTest?.sources?.assets?.addGeneratedSourceDirectory(preparePlaybackTestMedia, PreparePlaybackTestMedia::outputDirectory)
}
