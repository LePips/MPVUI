# Testing

Build and select the [Apple native libraries](../Build/BUILD.md#apple-libraries) or prepare both [Android architectures](../Build/BUILD.md#android-libraries) before running playback tests.

## Shared core and Apple tests

```sh
brew bundle
make test-core
make test-unit
make test
```

`test-core` runs `Tests/Core`. `test-unit` includes the shared core and Apple unit suites. `test` adds integration tests. Coverage includes compiled Swift sources from both the core and Apple player. It excludes prebuilt native libraries and inactive platform branches.

The release coverage gate includes system behavior. On a logged-in Mac, enable those suites to enforce the [coverage thresholds](../Build/Tests/coverage-thresholds.json):

```sh
MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 MPVUI_RUN_NATIVE_AUDIO_TESTS=1 MPVUI_RUN_INTERLACE_VALIDATION=1 \
  make coverage ARGS='--lane all'
```

Partial runs can fall below these complete-suite thresholds even when every selected test passes.

Reports go to `.build/coverage`. Commands show tool output by default. Add `JSON=1` for a structured summary. For command options and result fields, see [Building](../Build/BUILD.md).

To run one suite or test the build scripts:

```sh
make test-swift ARGS='--filter MPVDolbyVisionPolicyTests'
make test-tools
```

Run playback and UI tests serially. Keep the desktop session logged in and unlocked for macOS rendering and picture-in-picture tests. A locked console can prevent displayed-frame readback even while the renderer reports ready. The test runners keep the display awake when required.

## Android

Kotlin unit tests and release lint run on the host:

```sh
make test-android
```

Shared Swift and instrumentation tests require a running Android 16+ emulator or connected device. Set `ANDROID_SERIAL` to the chosen target.

```sh
export ANDROID_SERIAL=EMULATOR_OR_DEVICE_SERIAL
make media
make test-core-android ARGS="--abi arm64-v8a --device $ANDROID_SERIAL"
make test-android-device
make test-android-example
make test-android-example-release
```

On an arm64 Android device or emulator, `make test-android-native ARGS="--serial $ANDROID_SERIAL"` exercises the production Profile 7 conversion and Dolby Vision GPU metadata helpers.

Use `--abi x86_64` for that architecture. Instrumentation checks native playback, rendered pixels, subtitles, recovery, content access, and surface lifetime. The example tests add shared UI and Activity lifecycle checks in debug and optimized release builds. Optional Dolby Vision reference tests skip when their local media is absent. See [Test media](TEST_MEDIA.md#reference-media).

## Consumer checks

Verify public package use independently of the repository's example app:

```sh
make test-apple-consumer
make test-android-consumer
```

The Apple check creates an independent Swift package. The Android check extracts a Maven bundle and builds Kotlin debug and optimized release apps. To exercise Android playback too, pass `ARGS='--device EMULATOR_OR_DEVICE_SERIAL'` to `test-android-consumer`.

## Test media and new tests

Tests generate and cache media locally, replacing missing, damaged, or outdated files. Run `make media` to prepare `.build/test-media` explicitly. See [Test media](TEST_MEDIA.md) for fixture groups and additions.

Shared core tests live in `Tests/Core`. Apple suites live in `Tests/Unit`, `Tests/Integration`, `Tests/System`, and `Tests/Benchmarks`, with helpers in `Tests/Support`. Android tests live beside their library or example module. Build-script tests and generators live in `Build/Tests`.

- Extend an existing suite when possible.
- Check behavior, failure handling, and recovery.
- Reuse `PlaybackFixture` and `NativePlaybackSession` for Apple playback setup.
- Use `eventually` to wait for a result instead of a fixed sleep.
- Fail when required media is missing. Explain skips for optional media or hardware.

## Native and system checks

After building native macOS libraries, run the high dynamic range (HDR), metadata, compositor, and buffer-pool harnesses with AddressSanitizer and UndefinedBehaviorSanitizer:

```sh
make test-native
```

Enable system suites explicitly:

```sh
MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 make test-swift ARGS='--filter MPVMacPictureInPictureTests'
MPVUI_RUN_NATIVE_AUDIO_TESTS=1 make test-swift ARGS='--filter MPVNativeAudioIntegrationTests'
MPVUI_RUN_INTERLACE_VALIDATION=1 make test-swift ARGS='--filter MPVInterlacedPlaybackTests'
```

Audio tests use the current output with playback muted. Hardware validation covers HDR appearance, display switching, external audio routes, picture in picture, and audible synchronization. Simulator and emulator results don't establish those behaviors.

## Device testing

To run Apple tests on a connected, unlocked device:

```sh
brew bundle
make device-project ARGS='--team APPLE_TEAM_ID'
make test-device ARGS='--device-id DEVICE_UDID'
```

The target runs tests serially with Release testability and provisioning support. Regenerate the project after changing test files.

For a simulator, run `make device-project` without a team, then `make test-simulator ARGS='--simulator-id SIMULATOR_UDID'`. Presentation and some GPU readback tests require physical hardware.

See [Device benchmarks](../Build/Benchmarks/README.md) for playback, CPU, memory, and profiling workflows. Run `make help TARGET=benchmark` for host benchmarks and `make rendering-media` for rendering charts.
