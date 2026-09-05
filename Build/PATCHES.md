# Patches

Order, source revisions, and checksums: [Inputs.lock.json](Inputs.lock.json).

### [0001-player-add-moltenvk-context](Patches/mpv/0001-player-add-moltenvk-context.patch)

Adds mpv’s MoltenVK rendering context, using a host-provided `CAMetalLayer`.

### [0002-enable-avfoundation-ao-tvos](Patches/mpv/0002-enable-avfoundation-ao-tvos.patch)

Enables AVFoundation audio on iOS/tvOS by excluding macOS-only device APIs.

### [0003-mpvui-external-surface-size](Patches/mpv/0003-mpvui-external-surface-size.patch)

Adds `external-surface-size` for explicit resizing. Repeated writes still trigger an update.

### [0004-moltenvk-preserve-8bit-sdr](Patches/mpv/0004-moltenvk-preserve-8bit-sdr.patch)

Disables 10-bit SDR swapchain selection for MoltenVK, preserving 8-bit SDR output.

### [0005-mpvui-text-subtitle-interception](Patches/mpv/0005-mpvui-text-subtitle-interception.patch)

Adds opt-in `sub-text-intercept` and structured `sub-text-snapshot` properties,
preserving cue order and WebVTT settings. Styled ASS/SSA and bitmap subtitles
keep mpv rendering.

### [0006-moltenvk-coordinated-surface-resize](Patches/mpv/0006-moltenvk-coordinated-surface-resize.patch)

Synchronizes swapchain resizing, validates dimensions, and attempts rollback on
failure. Reports resize success through libmpv; success does not guarantee a
presented frame. Uses `pl_gpu_finish`, which can add resize latency.

### [0007-swift-frontend-object-output](Patches/mpv/0007-swift-frontend-object-output.patch)

Uses the Swift frontend to emit a Mach-O object for `libmpv.a`, avoiding a nested
static archive.

### [0008-swift-explicit-include-paths](Patches/mpv/0008-swift-explicit-include-paths.patch)

Uses explicitly quoted Swift include paths from the build recipe, fixing builds
in directories containing spaces.

### [0001-metal-pixelbuffer-compatibility](Patches/ffmpeg/0001-metal-pixelbuffer-compatibility.patch)

Requests Metal-compatible VideoToolbox pixel buffers in FFmpeg.
