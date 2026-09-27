# Video rendering

`MPVVideoPlayer` hosts the video layer; `MPVPlayer` controls playback through the [patched native library](PATCHES.md).

| Output | Rendering path | Use |
| --- | --- | --- |
| Metal | mpv → libplacebo → MoltenVK → `CAMetalLayer` | Scaling, tone mapping, custom shaders, and rendering presets |
| Sample buffer | mpv → AVFoundation → `AVSampleBufferDisplayLayer` | Native presentation, supported Dolby Vision metadata, and iOS PiP |

Sample buffers are the default on every platform. Custom rendering settings or additional mpv options select Metal. Set `videoOutput` to choose an output explicitly.

```swift
let player = MPVPlayer(configuration: .init(videoOutput: .sampleBuffer))
```

Unsupported native formats or missing metadata can trigger a switch to Metal. `player.videoOutput` reports the active output; `videoOutputFallbackReason` explains a switch. Metal shaders and presets apply only to Metal output.

Automatic output selection can switch to Metal for styled subtitles, baked overlays, or zoom and pan. Raw rendering properties and commands keep Metal active across later loads. Explicit sample-buffer output prioritizes Dolby Vision; set `nativeVideoFeaturePolicy` to prefer features instead.

## HDR and PiP

`hdrPolicy` controls dynamic range; `sdrOutput` controls Metal SDR precision. Native dynamic-range overrides, constrained HDR, and Metal HDR on tvOS depend on OS 26 APIs. Native SDR requests on older systems fall back to Metal. `player.mediaInformation.hdr` and `player.playbackDiagnostics` expose metadata and playback observations.

iOS PiP requires sample-buffer output. macOS supports both outputs through its private `PIP.framework` presenter. Use `videoOverlay` for content that should travel with the video into PiP.

## Display matching

`MPVDisplayMatchingContent` builds the content description, while `MPVDisplayMatchingCoordinator` owns matching policy, surface handoff, and mode-switch lifecycle on every supported platform. `MPVDisplayMatchingTarget` is the platform-neutral boundary: it accepts content hints, reports matching/switching state, and forwards change events. OS-specific types and notifications stay in `MPVPlatformDisplayMatchingTarget`. An unavailable endpoint releases matching without changing native HDR presentation.

On tvOS, the active `MPVVideoPlayer` surface supplies the window's `AVDisplayManager` with content frame rate and color format through [`AVDisplayCriteria`](https://developer.apple.com/documentation/avfoundation/avdisplaycriteria). Enable **Match Dynamic Range** and **Match Frame Rate** in Apple TV Settings → Video and Audio → Match Content. tvOS chooses an available HDMI mode subject to those settings and the connected route's capabilities.

Native Dolby Vision output advertises `dvh1` with a `dvcC` (Profile 5) or `dvvC` (Profile 8.1/8.4) configuration record after the decoder validates its session and per-frame RPU metadata. The hint uses the effective output profile, including Profile 8.1 after an explicitly enabled Profile 7 conversion. Source tags or conversion intent alone do not establish native Dolby Vision. Metal output advertises its HDR/SDR color characteristics without a Dolby Vision claim; disabling HDR removes HDR and Dolby Vision hints.

Frame-rate matching preserves fractional rates such as 24000/1001 (23.976) separately from 24. Criteria update when timing, output backend, or native Dolby Vision validation changes. Seeks and buffering retain the current hint, display switches suspend the media clock, and stopping or removing the active surface restores the system's default criteria.

The public window display-manager API is tvOS-only among MPVUI's supported platforms. A Dolby Vision source, HDR-capable display, or submitted display hint is not confirmation of the TV's current signal. Verify its status display on physical hardware.

## Subtitles and fonts

Use the text-subtitle APIs for app-rendered plain text. Styled ASS and bitmap subtitles stay in mpv's renderer. `subtitleLuminance` controls HDR subtitle white.

MPVUI bundles no fonts. Before creating the player, set `additionalOptions` entries `sub-fonts-dir` to an app-owned `.ttf`/`.otf` directory and `sub-font` to a font's internal family name. Keep the directory available during playback. The family supplies unstyled text and missing ASS fonts or glyphs. Apps rendering `textSubtitleStream()` snapshots choose fonts in their own UI.
