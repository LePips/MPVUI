# Video rendering

`MPVVideoPlayer` hosts the video layer; `MPVPlayer` controls playback through the [patched native library](PATCHES.md).

| Output        | Rendering path                                    | Use                                                               |
| ------------- | ------------------------------------------------- | ----------------------------------------------------------------- |
| Metal         | mpv → libplacebo → MoltenVK → `CAMetalLayer`      | Scaling, tone mapping, custom shaders, and rendering presets      |
| Sample buffer | mpv → AVFoundation → `AVSampleBufferDisplayLayer` | Native presentation, supported Dolby Vision metadata, and iOS PiP |

Sample buffers are the default on every platform. Only `videoOutput` selects the renderer, and it remains fixed for the player’s lifetime. Unsupported renderer settings have no effect. See [renderer option support](VIDEO_RENDERERS.md) for the support matrix and source evidence.

```swift
let player = MPVPlayer(configuration: .init(videoOutput: .sampleBuffer))
```

Unsupported native formats or missing required metadata report a playback error. Native sample buffers support subtitles, overlays, and geometry for ordinary video; native Dolby Vision preserves unmodified RPU frames and cannot bake these features into them. Metal shaders and presets apply only to Metal output.

## HDR and PiP

`hdrPolicy` controls dynamic range; `sdrOutput` controls Metal SDR precision. Native HDR overrides require OS 26; earlier systems keep automatic native HDR behavior. Constrained HDR and Metal HDR on tvOS require OS 26. `player.mediaInformation.hdr` and `player.playbackDiagnostics` expose metadata and playback observations.

Metal EDR uses linear float output with an effectively zero black level. SDR uses automatic contrast.

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
