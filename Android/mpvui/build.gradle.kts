import com.android.build.api.dsl.LibraryExtension
import groovy.json.JsonSlurper
import java.security.MessageDigest

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.compose")
    id("maven-publish")
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }

group = "io.github.lepips"
version = providers.gradleProperty("mpvuiVersion").get()
val nativeRoot = rootProject.layout.projectDirectory.dir("../.build/android/native")
val nativeVerifier = rootProject.file("../Build/Android/release.py").absolutePath

extensions.configure<LibraryExtension> {
    namespace = "mpvui"
    compileSdk = 36
    defaultConfig {
        minSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }
    sourceSets["main"].jniLibs.srcDir(nativeRoot.dir("jniLibs"))
    sourceSets["main"].assets.srcDir(nativeRoot.dir("assets"))
    sourceSets["androidTest"].assets.srcDir(rootProject.file("../.build/test-media"))
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    publishing { singleVariant("release") { withSourcesJar() } }
    testOptions {
        targetSdk = 36
        unitTests.isReturnDefaultValues = true
        animationsDisabled = true
    }
}
abstract class PrepareDolbyTestMedia : Sync() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    init { into(outputDirectory) }
}
val prepareDolbyTestMedia = tasks.register<PrepareDolbyTestMedia>("prepareDolbyTestMedia") {
    from(providers.environmentVariable("MPVUI_DOLBY_VISION_CHART").orElse(
        rootProject.file("../Example/Sources/MPVUIExample/Resources/Media/dolby-vision-p5-chart.mp4").absolutePath)) {
        rename { "dolby-vision-p5-chart.mp4" }
    }
    outputDirectory.set(layout.buildDirectory.dir("dolby-test-assets"))
}
androidComponents.onVariants { variant ->
    variant.androidTest?.sources?.assets?.addGeneratedSourceDirectory(prepareDolbyTestMedia, PrepareDolbyTestMedia::outputDirectory)
}
dependencies {
    implementation("androidx.core:core:1.17.0")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    api(platform("androidx.compose:compose-bom:2025.08.00"))
    api("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.2")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
val verifyNative by tasks.registering {
    doLast {
        // Reject stale source/compiler inputs as well as altered packaged bytes.
        providers.exec { commandLine("python3", nativeVerifier, "--verify-only") }.result.get().assertNormalExitValue()
        for (abi in listOf("arm64-v8a", "x86_64")) {
            val folder = nativeRoot.dir("jniLibs/$abi").asFile
            val manifestFile = nativeRoot.file("assets/mpvui/build-$abi.json").asFile
            check(manifestFile.isFile) { "Build both native ABIs with make build PLATFORM=android" }
            val manifest = JsonSlurper().parse(manifestFile) as Map<*, *>
            val inventory = manifest["libraries"] as Map<*, *>
            check(inventory.keys.containsAll(listOf("libmpv.so", "libmpvui.so", "libMPVCoreAndroid.so", "libswiftCore.so", "libc++_shared.so"))) {
                "Incomplete native inventory for $abi"
            }
            check(folder.listFiles()?.filter { it.extension == "so" }?.map { it.name }?.toSet() == inventory.keys) {
                "Stale or missing native libraries for $abi"
            }
            inventory.forEach { (name, expected) ->
                val library = folder.resolve(name as String)
                check(library.isFile) { "Missing $abi/$name" }
                val actual = MessageDigest.getInstance("SHA-256").digest(library.readBytes()).joinToString("") { "%02x".format(it) }
                check(actual == expected) { "Checksum mismatch for $abi/$name; run make build PLATFORM=android" }
            }
        }
    }
}
tasks.matching { it.name.contains("JniLibFolders") }.configureEach { dependsOn(verifyNative) }
afterEvaluate {
    publishing {
        publications { create<MavenPublication>("release") {
            from(components["release"])
            artifactId = "mpvui"
            pom {
                name.set("MPVUI")
                description.set("Kotlin and Compose video playback backed by libmpv")
                url.set("https://github.com/LePips/MPVUI")
                licenses { license { name.set("GNU General Public License v3.0 or later"); url.set("https://www.gnu.org/licenses/gpl-3.0.html") } }
                scm { url.set("https://github.com/LePips/MPVUI") }
            }
        } }
        repositories { maven { name = "localBundle"; url = uri(rootProject.layout.buildDirectory.dir("repository")) } }
    }
}
