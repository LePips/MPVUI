package mpvui

/** Frame-rate requests are hints; Android and the user's display settings decide the mode. */
enum class DisplayMatching {
    DISABLED,
    /** Requests seamless frame-rate matching when supported by Android and user settings. */
    AUTOMATIC,
    /** Also permits non-seamless changes when enabled in system display settings. */
    ALWAYS,
}

data class DeinterlacePolicy(
    val mode: Mode = Mode.DISABLED,
    val algorithm: Algorithm = Algorithm.AUTOMATIC,
    val fieldOrder: FieldOrder = FieldOrder.AUTOMATIC,
    val analyzeFieldOrder: Boolean = false,
) {
    enum class Mode { DISABLED, AUTOMATIC, FORCED }
    enum class Algorithm { AUTOMATIC, BWDIF, YADIF }
    enum class FieldOrder(val mpvName: String) { AUTOMATIC("auto"), TOP_FIRST("tff"), BOTTOM_FIRST("bff") }

}

/** gpu-next settings. Automatic resolves Android Battery Saver at player creation. */
data class RenderingQuality(
    val preset: Preset = Preset.AUTOMATIC,
    val scaling: Scaling? = null,
    val chromaScaling: Scaling? = null,
    val antiringing: Double? = null,
    val chromaAntiringing: Double? = null,
    val debanding: Boolean? = null,
    val dithering: Dithering? = null,
    val toneMapping: ToneMapping? = null,
    val gamutMapping: GamutMapping? = null,
    val peakDetection: PeakDetection? = null,
    val shaders: List<String> = emptyList(),
    val lut: LUT? = null,
) {
    enum class Preset { AUTOMATIC, BATTERY, BALANCED, HIGH_QUALITY }
    enum class Scaling(val mpvName: String) { BILINEAR("bilinear"), BICUBIC("bicubic"), LANCZOS("lanczos"), EWA_LANCZOS("ewa_lanczos"), EWA_LANCZOS_SHARP("ewa_lanczossharp") }
    enum class Dithering(val mpvName: String) { AUTOMATIC("fruit"), DISABLED("no"), ORDERED("ordered"), FRUIT("fruit"), ERROR_DIFFUSION("error-diffusion") }
    enum class ToneMapping(val mpvName: String) { AUTOMATIC("auto"), SPLINE("spline"), MOBIUS("mobius"), REINHARD("reinhard"), HABLE("hable"), CLIP("clip"), BT2390("bt.2390") }
    enum class GamutMapping(val mpvName: String) { AUTOMATIC("auto"), PERCEPTUAL("perceptual"), RELATIVE("relative"), SATURATION("saturation"), ABSOLUTE("absolute"), DESATURATE("desaturate"), DARKEN("darken"), CLIP("clip") }
    enum class PeakDetection(val mpvName: String) { AUTOMATIC("auto"), ENABLED("yes"), DISABLED("no") }
    data class LUT(val domain: Domain = Domain.NATIVE, val path: String) {
        enum class Domain(val mpvName: String) { NATIVE("native"), NORMALIZED("normalized") }
    }

}

/** Shared feature names; availability still reflects each renderer's actual capabilities. */
enum class VideoFeature { NATIVE_SUBTITLES, BAKED_OVERLAYS, ZOOM_AND_PAN, INLINE_OVERLAYS, PICTURE_IN_PICTURE_SUBTITLES }

data class VideoFeatureCapabilities(val backend: VideoOutput? = null, val hasVideo: Boolean = false,
                                    val features: Map<VideoFeature, Capability> = emptyMap()) {
    enum class Availability { AVAILABLE, UNAVAILABLE, UNKNOWN }
    enum class Restriction { AWAITING_VIDEO_METADATA, NATIVE_SURFACE_COMPOSITION_UNAVAILABLE,
        NATIVE_DOLBY_VISION_PRESERVES_RPU, PICTURE_IN_PICTURE_REQUIRES_NATIVE_OUTPUT, PICTURE_IN_PICTURE_UNAVAILABLE_ON_PLATFORM }
    data class Capability(val availability: Availability, val restriction: Restriction? = null)
    operator fun get(feature: VideoFeature): Capability = features[feature]
        ?: Capability(Availability.UNKNOWN, Restriction.AWAITING_VIDEO_METADATA)
}

internal fun displayFrameRate(value: Double): Float {
    if (!value.isFinite() || value <= 0 || value > 240) return 0f
    val standards = doubleArrayOf(24000.0 / 1001, 24.0, 25.0, 30000.0 / 1001, 30.0,
        48000.0 / 1001, 48.0, 50.0, 60000.0 / 1001, 60.0, 100.0, 120000.0 / 1001, 120.0)
    return (standards.firstOrNull { kotlin.math.abs(it - value) < .001 } ?: value).toFloat()
}

internal data class SurfacePresentation(
    val frameRate: Float = 0f, val keepScreenOn: Boolean = false, val hdrHeadroom: Float = 0f,
)

internal fun PlaybackSnapshot.surfacePresentation(configuration: PlayerConfiguration): SurfacePresentation {
    val visibleFrame = hasVideoFrame && state !in setOf(PlaybackState.IDLE, PlaybackState.LOADING, PlaybackState.STOPPED, PlaybackState.FAILED)
    val playing = visibleFrame && !paused && state in setOf(PlaybackState.PLAYING, PlaybackState.BUFFERING, PlaybackState.SEEKING)
    return SurfacePresentation(
        frameRate = if (playing && configuration.displayMatching != DisplayMatching.DISABLED)
            displayFrameRate((diagnostics.containerFramesPerSecond ?: 0.0) * playbackRate) else 0f,
        keepScreenOn = playing,
        // A paused native frame still needs its headroom. Clear it on renderer fallback or item removal.
        hdrHeadroom = if (visibleFrame && diagnostics.videoOutput == "mediacodec_embed" && configuration.hdrPolicy == HDRPolicy.AUTOMATIC)
            configuration.desiredHDRHeadroom else 0f,
    )
}
