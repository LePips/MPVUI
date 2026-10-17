#!/usr/bin/env python3
"""Verify an extracted Maven bundle in an independent Kotlin Android application."""

import argparse
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Build"))
from validation import publish_evidence
from Android.release import configured_version


def run_apk(adb, device, apk, label, destination):
    """Wait for a playback result from the actual app, including its R8 release."""
    command = [str(adb), "-s", device]
    application = "io.github.mpvui.consumer"
    token = uuid.uuid4().hex
    marker = f"MPVUI_CONSUMER {token} ".encode()
    subprocess.run([*command, "install", "-r", str(apk)], check=True)
    subprocess.run([*command, "shell", "am", "force-stop", application], check=True)
    output = bytearray()
    logs = subprocess.Popen(
        [*command, "logcat", "-v", "brief", "-s", "MPVUIConsumer:I", "AndroidRuntime:E", "*:S"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(logs.stdout, selectors.EVENT_READ)
            subprocess.run(
                [
                    *command,
                    "shell",
                    "am",
                    "start",
                    "-W",
                    "-n",
                    f"{application}/.ConsumerActivity",
                    "--es",
                    "probe",
                    token,
                ],
                check=True,
            )
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(logs.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(f"{label} consumer log stream ended before playback completed")
                output.extend(chunk)
                if marker + b"FAIL " in output:
                    raise RuntimeError(f"{label} consumer failed playback; see {destination / (label + '.log')}")
                if marker + b"PASS " in output:
                    print(f"Independent {label} consumer presented video through the packaged Swift core.")
                    return
            raise TimeoutError(f"{label} consumer did not report playback within 45 seconds")
    finally:
        logs.terminate()
        try:
            logs.wait(timeout=5)
        except subprocess.TimeoutExpired:
            logs.kill()
            logs.wait()
        logs.stdout.close()
        destination.mkdir(parents=True, exist_ok=True)
        (destination / f"{label}.log").write_bytes(output)
        subprocess.run([*command, "shell", "am", "force-stop", application], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=configured_version())
    parser.add_argument("--device", help="Also run the extracted consumer on this connected Android device")
    args = parser.parse_args()
    subprocess.run([sys.executable, ROOT / "Build/Android/release.py", "--version", args.version], check=True)
    bundle = ROOT / f".build/android/releases/{args.version}/mpvui-android-{args.version}-maven.zip"
    with tempfile.TemporaryDirectory(prefix="mpvui-kotlin-consumer-") as directory:
        consumer = Path(directory)
        with zipfile.ZipFile(bundle) as archive:
            archive.extractall(consumer / "repository")
        (
            consumer / "settings.gradle.kts"
        ).write_text("""pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
            dependencyResolutionManagement { repositories { maven { url = uri("repository") }; google(); mavenCentral() } }
            rootProject.name = "IndependentKotlinConsumer"
        """)
        (consumer / "build.gradle.kts").write_text(
            """plugins { id("com.android.application") version "9.2.0" }
            android {
                namespace = "io.github.mpvui.consumer"
                compileSdk = 36
                defaultConfig {
                    applicationId = "io.github.mpvui.consumer"
                    minSdk = 36
                    targetSdk = 36
                    ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
                }
                compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
                buildTypes { release {
                    isMinifyEnabled = true
                    signingConfig = signingConfigs.getByName("debug")
                    proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
                } }
            }
            dependencies {
                implementation("io.github.lepips:mpvui:@MPVUI_VERSION@")
            }
        """.replace("@MPVUI_VERSION@", args.version)
        )
        (consumer / "gradle.properties").write_text("android.useAndroidX=true\norg.gradle.jvmargs=-Xmx3g\n")
        sources = consumer / "src/main/java/io/github/mpvui/consumer"
        sources.mkdir(parents=True)
        (consumer / "src/main/AndroidManifest.xml").write_text("""<manifest xmlns:android="http://schemas.android.com/apk/res/android">
            <application android:theme="@android:style/Theme.Material.Light.NoActionBar">
                <activity android:name=".ConsumerActivity" android:exported="true" />
            </application></manifest>""")
        (sources / "ConsumerActivity.kt").write_text("""package io.github.mpvui.consumer
            import android.app.Activity
            import android.os.Bundle
            import mpvui.*
            class ConsumerActivity : Activity() {
                lateinit var player: MPVPlayer
                override fun onCreate(state: Bundle?) {
                    super.onCreate(state)
                    player = MPVPlayer(this, PlayerConfiguration(hardwareDecoding = HardwareDecoding.DISABLED,
                        audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
                    setContentView(MPVPlayerView(this).also { it.player = player })
                    val media = java.io.File(cacheDir, "consumer.mp4")
                    assets.open("baseline.mp4").use { input -> media.outputStream().use { input.copyTo(it) } }
                    player.load(media.absolutePath)
                    intent.getStringExtra("probe")?.let { token ->
                        Thread({
                            val deadline = System.nanoTime() + 30_000_000_000L
                            var snapshot = player.state.value
                            while (System.nanoTime() < deadline && snapshot.error == null &&
                                (!snapshot.hasVideoFrame || snapshot.position <= .2)) {
                                Thread.sleep(40)
                                snapshot = player.state.value
                            }
                            val status = if (snapshot.error == null && snapshot.hasVideoFrame && snapshot.position > .2) "PASS" else "FAIL"
                            android.util.Log.i("MPVUIConsumer", "MPVUI_CONSUMER $token $status frame=${snapshot.hasVideoFrame} position=${snapshot.position} error=${snapshot.error}")
                            runOnUiThread { finish() }
                        }, "Consumer playback probe").start()
                    }
                }
                override fun onDestroy() { player.close(); super.onDestroy() }
            }
        """)
        assets = consumer / "src/main/assets"
        assets.mkdir()
        shutil.copy2(ROOT / ".build/test-media/baseline.mp4", assets)
        destination = ROOT / ".build/android/consumer"
        results = destination / "results"
        shutil.rmtree(results, ignore_errors=True)
        results.mkdir(parents=True)
        try:
            subprocess.run(
                [ROOT / "Android/gradlew", "-p", consumer, "assembleDebug", "assembleRelease"],
                check=True,
            )
            if args.device:
                sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
                for variant in ("debug", "release"):
                    apks = list((consumer / "build/outputs/apk" / variant).glob("*.apk"))
                    if len(apks) != 1:
                        raise RuntimeError(f"Expected one {variant} consumer APK, found {apks}")
                    run_apk(sdk / "platform-tools/adb", args.device, apks[0], variant, results)
        finally:
            destination.mkdir(parents=True, exist_ok=True)
            for source, name in (("apk", "apk"), ("mapping", "mapping")):
                target = destination / name
                shutil.rmtree(target, ignore_errors=True)
                if (consumer / "build/outputs" / source).exists():
                    shutil.copytree(consumer / "build/outputs" / source, target)
            publish_evidence(artifacts={"consumerArtifacts": destination, "mavenBundle": bundle})
        publish_evidence(
            summary={
                "independentKotlinConsumer": "passed",
                "runtimeDevice": args.device,
                "runtimeBuildTypes": ["debug", "release"] if args.device else [],
            },
            artifacts={"consumerArtifacts": destination, "mavenBundle": bundle},
        )


if __name__ == "__main__":
    main()
