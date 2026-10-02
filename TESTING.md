# Testing

## Run tests

[Build and select the native libraries](Build/BUILD.md), then run these commands from the repository root:

```sh
brew install python ffmpeg webp dovi_tool
make test-unit  # Unit tests
make test       # Unit and integration tests
make coverage   # Unit and integration tests with coverage thresholds
```

Coverage reports go to `.build/coverage`. The [thresholds](Build/Tests/coverage-thresholds.json) apply to compiled Swift sources, not the prebuilt native libraries.

To run one player suite or test the build scripts:

```sh
make test-swift ARGS='--filter MPVDolbyVisionPolicyTests'
make test-tools  # Swift build-tool tests and both Python tooling suites
```

Run playback and UI tests serially. In Xcode, use the `MPVUI` scheme with parallel testing disabled. Stay logged in for macOS rendering and PiP tests. The Makefile runs `caffeinate -disu` to keep the display awake.

## Test media

The build generates and caches test media locally, replacing missing, damaged, or outdated files.

To generate media manually in `.build/test-media`:

```sh
make media
```

Use `make help TARGET=media` for groups and output options, then pass them through `ARGS`. See [Test media](TEST_MEDIA.md) for fixtures, additions, and coverage gaps.

## Write tests

Tests live in `Tests/Unit`, `Tests/Integration`, `Tests/System`, and `Tests/Benchmarks`. Shared helpers live in `Tests/Support`. Build-script tests and media generators live in `Build/Tests`.

- Add cases to the feature's existing suite when possible.
- Check what the player does, including how it fails and recovers.
- Reuse `PlaybackFixture` and `NativePlaybackSession` for playback setup.
- Use `eventually` to wait for a result instead of a fixed sleep.
- Fail when required media is missing. Explain skips for optional media or hardware.

## Native and system checks

After building the native macOS libraries, run the HDR, metadata, compositor, and buffer-pool tests with AddressSanitizer and UndefinedBehaviorSanitizer:

```sh
make test-native
```

Enable system tests explicitly:

```sh
MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 make test-swift ARGS='--filter MPVMacPictureInPictureTests'
MPVUI_RUN_NATIVE_AUDIO_TESTS=1 make test-swift ARGS='--filter MPVNativeAudioIntegrationTests'
MPVUI_RUN_INTERLACE_VALIDATION=1 make test-swift ARGS='--filter MPVInterlacedPlaybackTests'
```

Audio tests use the current output with playback muted. Use compatible headphones to check Spatial Audio and head tracking manually. Check HDR appearance, display switching, PiP, and audio/video sync on real hardware.

Run `make help TARGET=benchmark` for benchmarks and `make rendering-media` to create rendering charts.

## Device testing

See [device benchmarks](Build/Benchmarks/README.md) for CPU, memory, and playback measurements on an iPhone or iPad.

To run the tests on a connected, unlocked device:

```sh
brew install xcodegen
make device-project ARGS='--team APPLE_TEAM_ID'
make test-device ARGS='--device-id DEVICE_UDID'
```

Replace `APPLE_TEAM_ID` with your development team ID and `DEVICE_UDID` with the identifier shown in Xcode's Devices and Simulators window. Use `make help TARGET=test-device` for additional test options. The target runs tests serially with Release testability and provisioning support.

You can also open the generated project in Xcode, select `MPVUIRegressionTests` and your device, and choose **Product > Test**. Regenerate the project after adding or removing tests.

For a simulator, use `make device-project` without a team and `make test-simulator ARGS='--simulator-id SIMULATOR_UDID'`. Presentation and some GPU readback tests require a physical device.
