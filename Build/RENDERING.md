# Video rendering

`MPVVideoPlayer` hosts the video layer; `MPVPlayer` controls playback through the [patched native library](PATCHES.md).

| Output | Rendering path | Use |
| --- | --- | --- |
| Metal (default) | mpv → libplacebo → MoltenVK → `CAMetalLayer` | Scaling, tone mapping, custom shaders, and rendering presets |
| Sample buffer | mpv → AVFoundation → `AVSampleBufferDisplayLayer` | Native presentation, supported Dolby Vision metadata, and iOS PiP |

```swift
let player = MPVPlayer(configuration: .init(videoOutput: .sampleBuffer))
```

Unsupported native formats or missing metadata can trigger a switch to Metal. `player.videoOutput` reports the active output; `videoOutputFallbackReason` explains a switch. Metal shaders and presets apply only to Metal output.

## HDR and PiP

`hdrPolicy` controls dynamic range; `sdrOutput` controls Metal SDR precision. Native dynamic-range overrides, constrained HDR, and Metal HDR on tvOS depend on OS 26 APIs. Native SDR requests on older systems fall back to Metal. `player.mediaInformation.hdr` and `player.playbackDiagnostics` expose metadata and playback observations.

iOS PiP requires sample-buffer output. macOS supports both outputs through its private `PIP.framework` presenter. Use `videoOverlay` for content that should travel with the video into PiP.

## Subtitles and fonts

Use the text-subtitle APIs for app-rendered plain text. Styled ASS and bitmap subtitles stay in mpv's renderer. `subtitleLuminance` controls HDR subtitle white.

MPVUI bundles no fonts. Before creating the player, set `additionalOptions` entries `sub-fonts-dir` to an app-owned `.ttf`/`.otf` directory and `sub-font` to a font's internal family name. Keep the directory available during playback. The family supplies unstyled text and missing ASS fonts or glyphs. Apps rendering `textSubtitleStream()` snapshots choose fonts in their own UI.
