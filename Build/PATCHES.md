# Patches

[Inputs.lock.json](Inputs.lock.json) pins the source revisions, patch order, and SHA-256 checksums. The build applies these patches before compiling mpv and FFmpeg.

See [credits and licenses](Patches/AVFOUNDATION_CREDITS.md), [rendering](RENDERING.md), and [native test instructions](../TESTING.md#native-and-system-checks).

## mpv

| Patch | Purpose |
| --- | --- |
| [0001-moltenvk-embedding](Patches/mpv/0001-moltenvk-embedding.patch) | Embed the app-owned Metal layer, pass drawable sizes, and coordinate surface resizing. |
| [0002-apple-audio-portability](Patches/mpv/0002-apple-audio-portability.patch) | Enable Apple audio output on iOS and tvOS and guard macOS-only audio APIs. |
| [0003-text-subtitle-interception](Patches/mpv/0003-text-subtitle-interception.patch) | Expose plain-text subtitle snapshots while leaving styled ASS and bitmap subtitles in mpv. |
| [0004-swift-object-build](Patches/mpv/0004-swift-object-build.patch) | Build Swift sources into one Mach-O object and preserve explicit include paths. |
| [0005-avfoundation-native-video](Patches/mpv/0005-avfoundation-native-video.patch) | Add AVFoundation video output with sample-buffer timing, seeking, and subtitle composition. |
| [0006-avfoundation-compressed-audio](Patches/mpv/0006-avfoundation-compressed-audio.patch) | Add optional AC3/EAC3 playback through AVPlayer, with bounded buffering and route recovery. |
| [0007-native-dolby-vision-compatibility](Patches/mpv/0007-native-dolby-vision-compatibility.patch) | Add opt-in lossy Dolby Vision Profile 7 conversion with decoder and output checks. |
| [0008-bounded-hardware-decoder-recovery](Patches/mpv/0008-bounded-hardware-decoder-recovery.patch) | Limit recovery attempts after a working native VideoToolbox HEVC decoder fails. |
| [0009-native-hdr-color-metadata](Patches/mpv/0009-native-hdr-color-metadata.patch) | Preserve native HDR color metadata and apply HDR subtitle luminance. |
| [0010-apple-rendering-quality](Patches/mpv/0010-apple-rendering-quality.patch) | Add Apple color-output handling, live surface updates, and rendering diagnostics. |
| [0011-native-subtitle-image-cache](Patches/mpv/0011-native-subtitle-image-cache.patch) | Reuse converted native subtitle images until the subtitle bitmap changes. |
| [0012-text-subtitle-queries](Patches/mpv/0012-text-subtitle-queries.patch) | Query complete text-subtitle tracks with cue times, cancellation, and paused updates. |
| [0013-subtitle-roles](Patches/mpv/0013-subtitle-roles.patch) | Include track identities and primary or secondary roles in text-subtitle snapshots. |
| [0014-webp-animation-duration](Patches/mpv/0014-webp-animation-duration.patch) | Include the final animated WebP frame in duration estimates. |

## FFmpeg

| Patch | Purpose |
| --- | --- |
| [0001-apple-pixelbuffer-compatibility](Patches/ffmpeg/0001-apple-pixelbuffer-compatibility.patch) | Create VideoToolbox buffers compatible with Metal and Core Animation. |
| [0002-native-dolby-vision](Patches/ffmpeg/0002-native-dolby-vision.patch) | Preserve supported native Dolby Vision metadata and associate it with its decoder session. |
| [0003-native-dolby-vision-compatibility](Patches/ffmpeg/0003-native-dolby-vision-compatibility.patch) | Add optional libdovi Profile 7 conversion and forward the converted RPU metadata. |
| [0004-hevc-diagnostic-levels](Patches/ffmpeg/0004-hevc-diagnostic-levels.patch) | Reduce duplicate HEVC diagnostic messages. |
| [0005-apple-dynamic-hdr-diagnostics](Patches/ffmpeg/0005-apple-dynamic-hdr-diagnostics.patch) | Preserve HDR10+ metadata and route native HDR diagnostics to the owning player. |
