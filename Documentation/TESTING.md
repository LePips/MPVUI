# Testing

Build and select the [Apple native libraries](../Build/BUILD.md#apple-libraries) or build the [Android libraries](../Build/BUILD.md#android-libraries) before running playback tests. `just test` runs the everyday suites for a platform, and `--suite` chooses another. Run `just help` to list the suites for each platform.

## Shared core and Apple tests

```sh
brew bundle
just test --suite core
just test --suite unit
just test
```

`--suite core` runs `Tests/Core`. `--suite unit` adds the Apple unit suites. The default adds integration tests. Coverage includes compiled Swift sources from both the core and Apple player. It excludes prebuilt native libraries and inactive platform branches.

The release coverage gate includes system behavior. On a logged-in Mac, enable those suites to enforce the [coverage thresholds](../Build/Tests/coverage-thresholds.json):

```sh
MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 MPVUI_RUN_NATIVE_AUDIO_TESTS=1 MPVUI_RUN_INTERLACE_VALIDATION=1 \
  just test --suite all -- --check
```

Partial runs can fall below these complete-suite thresholds even when every selected test passes.

Reports go to `.build/coverage`. Commands show tool output by default. Add `--json` for a structured summary. For command options and result fields, see [Building](../Build/BUILD.md).

To run matching tests without coverage, or test the build scripts:

```sh
just test --filter MPVDolbyVisionPolicyTests
just test --suite tools
```

Run playback and UI tests serially. Keep the desktop session logged in and unlocked for macOS rendering and picture-in-picture tests. A locked console can prevent displayed-frame readback even while the renderer reports ready. The test runners keep the display awake when required.

## Android

Kotlin unit tests and release lint run on the host:

```sh
just test --platform android
```

Shared Swift and instrumentation tests require a running Android 16+ emulator or connected device. Pass its serial as `--device`:

```sh
just test --platform android --suite core --device SERIAL
just test --platform android --suite integration --device SERIAL
just test --platform android --suite example --device SERIAL
just test --platform android --suite example --profile release --device SERIAL
```

Core tests run for the device's architecture. Instrumentation checks native playback, rendered pixels, subtitles, recovery, content access, and surface lifetime. The example tests add shared UI and Activity lifecycle checks in debug and optimized release builds. On an arm64 target, `--suite native` exercises the production Profile 7 conversion and Dolby Vision GPU metadata helpers. Optional Dolby Vision reference tests skip when their local media is absent. See [Test media](TEST_MEDIA.md#reference-media).

## Consumer checks

Verify public package use independently of the repository's example app:

```sh
just test --suite consumer
just test --platform android --suite consumer
```

The Apple check creates an independent Swift package. The Android check extracts a Maven bundle and builds Kotlin debug and optimized release apps. Add `--device` to run the Android consumer on an emulator or device too.

## Test media and new tests

Tests generate and cache media locally, replacing missing, damaged, or outdated files. `just setup` prepares `.build/test-media` ahead of time. See [Test media](TEST_MEDIA.md) for fixture groups and additions.

Shared core tests live in `Tests/Core`. Apple suites live in `Tests/Unit`, `Tests/Integration`, `Tests/System`, and `Tests/Benchmarks`, with helpers in `Tests/Support`. Android tests live beside their library or example module. Build-script tests and generators live in `Build/Tests`.

- Extend an existing suite when possible.
- Check behavior, failure handling, and recovery.
- Reuse `PlaybackFixture` and `NativePlaybackSession` for Apple playback setup.
- Use `eventually` to wait for a result instead of a fixed sleep.
- Fail when required media is missing. Explain skips for optional media or hardware.

## Native and system checks

After building native macOS libraries, run the high dynamic range (HDR), metadata, compositor, and buffer-pool harnesses with AddressSanitizer and UndefinedBehaviorSanitizer:

```sh
just test --suite native
```

Enable system suites explicitly:

```sh
MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 just test --filter MPVMacPictureInPictureTests
MPVUI_RUN_NATIVE_AUDIO_TESTS=1 just test --filter MPVNativeAudioIntegrationTests
MPVUI_RUN_INTERLACE_VALIDATION=1 just test --filter MPVInterlacedPlaybackTests
```

Audio tests use the current output with playback muted. Hardware validation covers HDR appearance, display switching, external audio routes, picture in picture, and audible synchronization. Simulator and emulator results don't establish those behaviors.

## Device testing

To run Apple tests on a connected, unlocked device or a simulator:

```sh
brew bundle
export MPVUI_DEVELOPMENT_TEAM=APPLE_TEAM_ID
just test --suite device --device UDID
```

Omit `--device` to list devices and simulators. The runner regenerates the test project each time, so it includes current test files. It runs tests serially with Release testability. Physical devices need a development team from `MPVUI_DEVELOPMENT_TEAM` or `-- --team APPLE_TEAM_ID`. Simulators don't. Presentation and some GPU readback tests require physical hardware.

See [Device benchmarks](../Build/Benchmarks/README.md) for playback, CPU, memory, and profiling workflows. `just benchmark` runs host benchmarks, and `just test --suite rendering` generates clips for manual rendering checks.
