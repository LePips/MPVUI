# Device benchmarks

Run from the repository root with XcodeBuildMCP, an Apple development team configured for device signing, and an iPhone or iPad. Keep the device unlocked and the app in the foreground. For comparisons, use the same device, media, audio route, display settings, power state, and Xcode version.

## Playback measurements

```sh
xcodebuildmcp device list
Build/benchmark device --label before --device DEVICE_ID \
  --media /path/to/video.mp4 --backend default --repetitions 3
Build/benchmark device --label after --device DEVICE_ID \
  --media /path/to/video.mp4 --backend default --repetitions 3
Build/benchmark compare /path/to/before.json /path/to/after.json
```

The runner builds the example in Release and alternates MPV and AVPlayer, starting a fresh process for each sample. Reports and logs go to `.build/benchmarks` without overwriting existing reports. Use `--players mpv` to measure MPV alone. `--skip-build` requires a saved build stamp matching the source, Xcode version, and app.

By default, runs measure 30 seconds after a 5-second warmup. Use seekable media more than 8 seconds longer than the combined warmup and sample. The app checks pause, seek, resume, stop, and player deallocation. MPV checks also verify the decoder session, renderer, playback progress, and no new frame drops during steady playback.

Use `--backend sampleBuffer` or `--backend metal` to choose an output. MPV also accepts `--software-decoding`, `--sdr-output compatibility8Bit`, and repeated `--option key=value` arguments. Run `Build/benchmark device --help` for timing and output options.

For HLS, supply a self-contained local playlist and the Mac's LAN address:

```sh
Build/benchmark device --label hls --device DEVICE_ID \
  --media /path/to/hls/index.m3u8 --host MAC_LAN_ADDRESS
```

The runner serves the playlist's local resources and records their hashes. All references must stay within the media directory. Allow local-network access on the device when prompted.

CPU measurements cover the app process and exclude AVPlayer work in system services. Memory samples occur every 100 ms and can miss short peaks. Do not add Metal allocations to physical footprint; they can overlap. Diagnostics update at their own intervals, and missing values remain unavailable. These results do not measure total energy use, visible smoothness, or audible synchronization.

## Playback regression

```sh
Build/benchmark device-regression --device DEVICE_ID \
  --media /path/to/video.mp4 --backend default
Build/benchmark device-regression --device DEVICE_ID \
  --media /path/to/hls/index.m3u8 --host MAC_LAN_ADDRESS \
  --backend sampleBuffer --skip-build
```

This run checks three pause/seek/stop/replay cycles, loading while stopped, playback-rate changes, and deallocation. Use seekable media at least 30 seconds long. Choose `--backend metal` or `--software-decoding` to test those paths. Failed checks return a nonzero exit status and keep their reports. Use the [package tests](../../TESTING.md#device-testing) for internal lifecycle and displayed-pixel checks.

## Comparing builds

`run_device_ab.py` compares two built checkouts in A/B, B/A, A/B order for direct-file and HLS playback. Each sample installs the selected app and starts a fresh process. Both checkouts need the same measurement protocol and saved build stamps. Reference reports must match the baseline.

```sh
python3 Build/Benchmarks/run_device_ab.py run --help
python3 Build/Benchmarks/run_device_ab.py assemble --plan /path/to/plan.json
```

The runner validates inputs by default; add `--execute` to start measurements. Runs use a 30-second sample, a 5-second warmup, and no custom MPV options. Assembly requires all twelve samples to pass. Compare reports with the same installation order.

## Profiling

Run a fresh Release benchmark before profiling. Use the same source, native binary, media, and device conditions for the reference and trace.

```sh
python3 Build/Benchmarks/capture_device_profile.py --device DEVICE_ID \
  --media /path/to/video.mp4 --reference /path/to/reference.json \
  --output .build/benchmarks/profiles/playback
python3 Build/Benchmarks/analyze_device_profile.py /path/to/capture \
  --products /path/to/Release-iphoneos --symbols /path/to/DeviceSupport/Symbols
```

Use `--help` for capture and analysis options, including a process ID when capture metadata is missing. Add `--host MAC_LAN_ADDRESS` for HLS. Use `--template 'System Trace'` to capture scheduling activity, then analyze its exported `thread-state` and `context-switch` tables with `analyze_device_system_trace.py`.

Capture steady playback. Analysis checks symbol UUIDs, keeps unresolved frames, and reports profiling overhead separately. Nested stack weights overlap; do not add them together or compare them directly with CPU measurements from an unprofiled run.

## Synchronization probe

`MPVNativeSynchronizationProbeTests` measures native timing during startup, steady playback, and seeking at two polling rates. Run it separately from performance measurements. After generating the device test project, prepare its resources using successful direct-file and HLS benchmark reports:

```sh
python3 Build/Benchmarks/prepare_sync_probe.py prepare \
  --direct /path/to/video.mp4 --hls /path/to/hls/index.m3u8 \
  --direct-report /path/to/direct.json --hls-report /path/to/hls.json \
  --hls-url http://MAC_LAN_ADDRESS:8765/hls/index.m3u8 \
  --output .build/device-tests/GeneratedMedia
python3 Build/Benchmarks/run_device_sync_probe.py \
  --device DEVICE_ID --host MAC_LAN_ADDRESS \
  --direct /path/to/video.mp4 --hls /path/to/hls/index.m3u8 \
  --output .build/benchmarks/sync
```

Regenerate the device test project after adding these resources.

The runner validates locally by default. Add `--execute` to start the media server, rebuild and run the tests, and collect four fresh reports. Keep the server port free. The runner verifies the media and source before and after testing. Native timing and frame counts do not measure physical display timing or audible lip sync.
