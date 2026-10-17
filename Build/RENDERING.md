# Video rendering

`MPVVideoPlayer` hosts the video layer. `MPVPlayer` controls playback through the shared session and [patched native library](PATCHES.md).

## Apple output

| Output        | Rendering path                                    | Use                                                               |
| ------------- | ------------------------------------------------- | ----------------------------------------------------------------- |
| Metal         | mpv → libplacebo → MoltenVK → `CAMetalLayer`      | Scaling, tone mapping, custom shaders, and rendering presets      |
| Sample buffer | mpv → AVFoundation → `AVSampleBufferDisplayLayer` | Native presentation, supported Dolby Vision metadata, and iOS PiP |

Sample-buffer output is the default. Choose `videoOutput` when creating the player. It stays fixed for the player's lifetime. Unsupported settings have no effect. See [MPVPlayerConfiguration](../Sources/Models/MPVPlayerConfiguration.swift) for option support.

```swift
let player = MPVPlayer(configuration: .init(videoOutput: .sampleBuffer))
```

Unsupported native formats or missing required metadata report a playback error. Native sample buffers support subtitles, overlays, and geometry changes for ordinary video. Native Dolby Vision preserves frames with reference processing unit (RPU) metadata, so it can't apply these features to the frames. Metal shaders and presets apply only to Metal output.

### Dynamic range and picture in picture

`hdrPolicy` controls high dynamic range (HDR). `sdrOutput` controls Metal standard dynamic range (SDR) precision. Native HDR overrides require OS 26. Earlier systems use automatic native HDR behavior. Constrained HDR and Metal HDR on tvOS require OS 26. `player.mediaInformation.hdr` and `player.playbackDiagnostics` expose metadata and playback observations.

Metal extended dynamic range (EDR) uses linear floating-point output with an effectively zero black level. SDR uses automatic contrast.

iOS picture in picture requires sample-buffer output. macOS supports both outputs through its private `PIP.framework` presenter. Use `videoOverlay` for content that should travel with the video into PiP.

### Display matching

On tvOS, the active video surface sends frame-rate and color hints through [`AVDisplayCriteria`](https://developer.apple.com/documentation/avfoundation/avdisplaycriteria). Enable **Match Dynamic Range** and **Match Frame Rate** in **Settings > Video and Audio > Match Content**. tvOS selects an HDMI mode supported by the settings, display, and connection.

Dolby Vision hints require a validated decoder session and per-frame RPU metadata. They describe the effective output profile, including Profile 8.1 after opt-in Profile 7 conversion. Source tags or a conversion request alone are insufficient. Metal supplies HDR and SDR hints. Disabling HDR removes HDR and Dolby Vision hints.

Matching distinguishes fractional rates such as 23.976 from 24 fps. Hints update when timing or validated output changes and remain stable through seeks and buffering. Display switches suspend the media clock. Stopping or removing the active surface restores default criteria.

Display matching is tvOS-only. When unavailable, native HDR presentation continues unchanged. Display hints don't confirm the TV's actual signal. Check the TV's status display.

### Subtitles and fonts

Use the text-subtitle APIs for app-rendered plain text. mpv renders styled ASS and bitmap subtitles. `subtitleLuminance` controls HDR subtitle white.

MPVUI bundles no fonts. Before creating the player, set these entries in `additionalOptions`:

- `sub-fonts-dir`: a directory containing the app's `.ttf` or `.otf` files.
- `sub-font`: the font's internal family name.

Keep the directory available during playback. mpv uses this family for unstyled text and as a fallback for missing ASS fonts or glyphs. Apps rendering `textSubtitleStream()` snapshots choose fonts in their own UI.

## Android output

Choose `PlayerConfiguration.videoOutput` when creating the player. Explicit choices remain selected and report unsupported requests. Only `AUTOMATIC` permits native-to-GPU fallback for the current item.

| Output           | Behavior                                                                                           |
| ---------------- | -------------------------------------------------------------------------------------------------- |
| `GPU`            | Default. Uses libplacebo and OpenGL ES for subtitle composition, filters, and tone mapping to SDR. |
| `NATIVE_SURFACE` | Uses MediaCodec's display surface for HDR on compatible codecs and displays.                       |
| `AUTOMATIC`      | Selects native output when the display and requested features allow it, with GPU fallback.         |

Native output doesn't support mpv's styled or bitmap subtitle composition, filters, or shaders. Text interception supplies snapshots for app overlays, and the Compose view provides a basic text overlay. Use GPU output when authored styling or video processing matters.

GPU output maps HDR10, HLG, and Dolby Vision to SDR. Native Dolby Vision requires device codec and display support. Opt-in Profile 7 compatibility conversion discards the enhancement layer and doesn't reconstruct its detail.

`PlaybackSnapshot.hdr` separates source metadata from output observations. Source tags and display capabilities don't confirm native HDR presentation. Check appearance and output switching on the target hardware. Android frame-rate hints also depend on device support and user settings.
