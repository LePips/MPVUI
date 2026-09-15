# Testing

MPVUI uses one Swift Testing target, organized by behavior and test level. Suite tags mirror the directory structure.

| Location | Purpose |
| --- | --- |
| `Tests/Unit` | Models, parsing, policies, and state with controlled inputs |
| `Tests/Integration` | Real mpv playback, rendering, subtitles, and platform views |
| `Tests/System` | Opt-in PiP, audio-route, and interlaced playback checks |
| `Tests/Benchmarks` | Opt-in performance measurements |
| `Tests/Support` | Fixtures, media paths, synchronization, and cleanup |
| `Tests/Resources` | Media used only by tests |
| `Build/Tests` | Build-tool checks, native patch tests, and fixture generators |

## Run tests

From the repository root, after [building and selecting a native artifact](Build/BUILD.md):

```sh
make -C Build test-unit
make -C Build test
make -C Build coverage
swift test --no-parallel --filter MPVDolbyVisionPolicyTests
swift test --package-path Build --no-parallel
```

`test` runs unit and integration suites. `coverage` runs the same suites and enforces [configured thresholds](Build/Tests/coverage-thresholds.json) for compiled Swift code under `Sources`. Reports stay in `.build/coverage`; native libraries and inactive platform code require separate checks.

Run live playback and UI suites serially. In Xcode, run the `MPVUI` package scheme on iOS and tvOS simulators with parallel testing disabled. macOS frame readback and system PiP need a logged-in session with an awake display; use `caffeinate -disu` for direct runs. The test runner handles this automatically.

## Write tests

- Add cases to the feature's existing suite, including dependency upgrades. Organize by behavior, without version-specific suites.
- Assert observable outcomes, including failures, boundaries, and recovery. Use parameterized cases for input variants.
- Share setup and cleanup through `PlaybackFixture`, `NativePlaybackSession`, and temporary directories. Keep expected results in the test.
- Use `eventually` for asynchronous readiness. Give optional media and platform skips an explicit reason; require mandatory fixtures.

## Media

Tests share the baseline and multitrack examples through `MPVUITestResources`. The baseline covers playback and external subtitles; the multitrack clip covers track selection, overlapping subtitles, and chapters. Test-only media covers subtitle formats, short and streaming AC3/EAC3 audio, and still/animated WebP. Each resource directory has a `Fixtures.lock.json` checksum manifest.

The Dolby Vision example stays local. Supply it through `MPVUI_DOLBY_VISION_FIXTURE` or the example's `Mystery Box Dolby Vision Profile 5.mp4`. Font tests copy installed host fonts into temporary directories.

```sh
python3 Build/Tests/generate_multitrack_fixture.py
python3 Build/Tests/generate_webp_fixture.py
```

The generators require FFmpeg/ffprobe and libwebp's CLI tools, respectively.

## Native and system checks

After building the native macOS target, run patched HDR/color/metadata code with address and undefined-behavior sanitizers:

```sh
python3 Build/Tests/NativeHDR/run.py
```

The small `profile5.rpu` file is a metadata parser fixture. Check HDR appearance, display switching, and PiP presentation on physical devices.

```sh
caffeinate -disu env MPVUI_RUN_MAC_PIP_SYSTEM_TESTS=1 swift test --no-parallel --filter MPVMacPictureInPictureTests
MPVUI_RUN_NATIVE_AUDIO_TESTS=1 swift test --no-parallel --filter MPVNativeAudioIntegrationTests
python3 Build/Tests/RenderingValidation/generate_interlaced.py
MPVUI_RUN_INTERLACE_VALIDATION=1 swift test --no-parallel --filter MPVInterlacedPlaybackTests
```

Audio tests use the real route and mute playback. Generate optional rendering media with `Build/Tests/RenderingValidation/generate.py`. Use `Build/benchmark --help` for performance runs and comparisons.
