# Testing

## Run tests

[Build and select a native artifact](Build/BUILD.md), then run from the repository root:

```sh
brew install python ffmpeg webp
make -C Build test-unit  # Unit tests
make -C Build test       # Unit and integration tests
make -C Build coverage   # Same tests, with coverage thresholds
```

Coverage checks compiled Swift sources against [configured thresholds](Build/Tests/coverage-thresholds.json). Reports go to `.build/coverage`.

For a specific suite or the build tools:

```sh
swift test --no-parallel --filter MPVDolbyVisionPolicyTests
swift test --package-path Build --no-parallel
python3 -m unittest discover -s Build/Tests -p 'test_*.py'
```

Run playback and UI tests serially. In Xcode, select the `MPVUI` package scheme and disable parallel testing for iOS and tvOS simulators. macOS frame readback and PiP tests need an awake display and logged-in session; prefix direct runs with `caffeinate -disu`. The Makefile test commands handle this automatically.

## Test media

No sample media is checked into Git. Tests automatically generate and cache codec, audio, subtitle, chapter, HDR, WebP, and interlaced fixtures before building. Missing, corrupt, or outdated files regenerate. Encoders run on the build host; generated files stay in ignored build output.

To generate media manually in `.build/test-media`:

```sh
python3 Build/Tests/prepare_test_media.py
```

Use `--help` for fixture groups and output options. To add a fixture, update its generator, register the outputs in [prepare_test_media.py](Build/Tests/prepare_test_media.py), and update the resource and codec tests.

Optional reference clips belong in the ignored example Media folder or `MPVUI_TEST_MEDIA_DIRECTORY`. Use `MPVUI_DOLBY_VISION_FIXTURE` for a Profile 5 chart override. [import_harness_media.py](Build/Tests/import_harness_media.py) can copy an existing local reference library.

## Write tests

Tests live in `Tests/Unit`, `Tests/Integration`, `Tests/System`, and `Tests/Benchmarks`. Shared helpers are in `Tests/Support`; build-tool tests and generators are in `Build/Tests`.

- Add cases to the feature's existing suite, organized by behavior.
- Check observable results, including failure and recovery. Parameterize input variants.
- Reuse `PlaybackFixture`, `NativePlaybackSession`, and temporary directories.
- Use `eventually` for asynchronous readiness. Require mandatory fixtures and explain optional skips.

## Native and system checks

After building the native macOS target, run HDR and metadata checks with address and undefined-behavior sanitizers:

```sh
brew install dovi_tool
python3 Build/Tests/NativeHDR/run.py
```

Opt-in system tests:

```sh
caffeinate -disu env MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 swift test --no-parallel --filter MPVMacPictureInPictureTests
MPVUI_RUN_NATIVE_AUDIO_TESTS=1 swift test --no-parallel --filter MPVNativeAudioIntegrationTests
MPVUI_RUN_INTERLACE_VALIDATION=1 swift test --no-parallel --filter MPVInterlacedPlaybackTests
```

Audio tests use the real route with playback muted. Check HDR appearance, display switching, and PiP on physical devices.

Use `Build/benchmark --help` for performance runs and [RenderingValidation/generate.py](Build/Tests/RenderingValidation/generate.py) for optional rendering charts.
