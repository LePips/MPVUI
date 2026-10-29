# Device benchmarks

Device benchmarks require Xcode command-line tools, an Apple development team configured for device signing, and an iPhone or iPad. Keep the device unlocked and the app in the foreground. For comparisons, use the same device, media, audio route, display settings, power state, and Xcode version.

`make benchmark` measures the host. Set `DEVICE` to measure on a device, and `STEP` for the other workflows below. Pass tool options through `ARGS`, and add `ARGS=--help` to list them.

## Playback measurements

```sh
make benchmark DEVICE=DEVICE_ID ARGS='--label before --media /path/to/video.mp4 --backend default --repetitions 3'
make benchmark DEVICE=DEVICE_ID ARGS='--label after --media /path/to/video.mp4 --backend default --repetitions 3'
make benchmark STEP=compare ARGS='/path/to/before.json /path/to/after.json'
```

Run `make test SUITE=device` without `DEVICE` to list device identifiers. The runner builds the example in Release and alternates mpv and AVPlayer, starting a fresh process for each sample. Reports and logs go to `.build/benchmarks` without overwriting existing reports. Use `--players mpv` to measure mpv alone. `--skip-build` requires a saved build stamp matching the source, Xcode version, and app.

Runs default to a 5-second warmup and 30-second sample. Use seekable media longer than 43 seconds, or more than 8 seconds beyond your chosen warmup and sample. The app checks pause, seek, resume, stop, and player deallocation. The mpv checks also verify the decoder session, renderer, and playback progress. They check that no new frames drop during steady playback.

Use `--backend sampleBuffer` or `--backend metal` to choose an output. mpv also accepts `--software-decoding`, `--sdr-output compatibility8Bit`, and repeated `--option key=value` arguments.

For HLS, supply a self-contained local playlist and the Mac's LAN address:

```sh
make benchmark DEVICE=DEVICE_ID ARGS='--label hls --media /path/to/hls/index.m3u8 --host MAC_LAN_ADDRESS'
```

The runner serves the playlist's local resources and records their hashes. All references must stay within the media directory. Allow local-network access on the device when prompted.

CPU measurements cover the app process and exclude AVPlayer work in system services. Memory samples occur every 100 ms and can miss short peaks. Metal allocations can overlap with physical footprint. Don't add them together. Diagnostics update at their own intervals, and missing values remain unavailable. These results don't measure total energy use, visible smoothness, or audible synchronization.

## Playback regression checks

```sh
make test SUITE=regression DEVICE=DEVICE_ID ARGS='--media /path/to/video.mp4 --backend default'
make test SUITE=regression DEVICE=DEVICE_ID ARGS='--media /path/to/hls/index.m3u8 --host MAC_LAN_ADDRESS --backend sampleBuffer --skip-build'
```

This run checks three pause/seek/stop/replay cycles, loading while stopped, playback-rate changes, and deallocation. Use seekable media at least 30 seconds long. Choose `--backend metal` or `--software-decoding` to test those paths. Failed checks return a nonzero exit status and keep their reports. Use the [package tests](../../Documentation/TESTING.md#device-testing) for internal lifecycle and displayed-pixel checks.

## Compare builds

`STEP=ab` compares two built checkouts in A/B, B/A, A/B order for direct-file and HLS playback. Each sample installs the selected app and starts a fresh process. Both checkouts need the same measurement protocol and valid saved build stamps. Reference reports must match the baseline.

```sh
make benchmark STEP=ab ARGS='run --help'
make benchmark STEP=ab ARGS='assemble --plan /path/to/plan.json'
```

The runner validates inputs by default. Add `--execute` to start measurements. Runs use a 30-second sample, a 5-second warmup, and no custom mpv options. Assembly requires all 12 samples to pass. Compare reports with the same installation order.

## Profiling

Run a fresh Release benchmark before profiling. Use the same source, native binary, media, and device conditions for the reference and trace.

```sh
make benchmark STEP=profile DEVICE=DEVICE_ID ARGS='--media /path/to/video.mp4 --reference /path/to/reference.json --output .build/benchmarks/profiles/playback'
make benchmark STEP=analyze ARGS='/path/to/capture --products /path/to/Release-iphoneos --symbols /path/to/DeviceSupport/Symbols'
```

Analysis accepts a process ID when capture metadata is missing. Add `--host MAC_LAN_ADDRESS` for HLS. Use `--template 'System Trace'` to capture scheduling activity, then analyze its exported `thread-state` and `context-switch` tables with `STEP=trace`.

Capture steady playback. Analysis checks symbol UUIDs, keeps unresolved frames, and reports profiling overhead separately. Nested stack weights overlap. Don't add them together or compare them directly with CPU measurements from an unprofiled run.

## Synchronization probe

`MPVNativeSynchronizationProbeTests` measures native timing during startup, steady playback, and seeking at two polling rates. Run it separately from performance measurements. Prepare its resources using successful direct-file and HLS benchmark reports:

```sh
make benchmark STEP=sync-prepare ARGS='prepare --direct /path/to/video.mp4 --hls /path/to/hls/index.m3u8 --direct-report /path/to/direct.json --hls-report /path/to/hls.json --hls-url http://MAC_LAN_ADDRESS:8765/hls/index.m3u8 --output .build/device-tests/GeneratedMedia'
make benchmark STEP=sync DEVICE=DEVICE_ID ARGS='--host MAC_LAN_ADDRESS --direct /path/to/video.mp4 --hls /path/to/hls/index.m3u8 --output .build/benchmarks/sync'
```

The runner validates inputs by default. Add `--execute` to regenerate the device test project, serve media, rebuild, run tests, and collect four fresh reports. Keep the server port free. The runner verifies media and source before and after testing. Native timing and frame counts don't measure physical display timing or audible lip sync.
