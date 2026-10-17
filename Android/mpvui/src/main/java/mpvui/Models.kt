package mpvui

/** Platform-independent playback concepts shared with the Swift API. Times are seconds. */
enum class PlaybackState {
    IDLE, LOADING, READY, PLAYING, PAUSED, BUFFERING, SEEKING, ENDED, STOPPED, FAILED;
    /** Whether playback is advancing. */
    val isPlaying: Boolean get() = this == PLAYING
    /** Whether playback is in a short-lived transition. */
    val isTransient: Boolean get() = this == LOADING || this == BUFFERING || this == SEEKING
    /** Whether the current playback attempt has finished. */
    val isTerminal: Boolean get() = this == ENDED || this == STOPPED || this == FAILED
}
enum class TrackType(val mpvName: String, val property: String) { VIDEO("video", "vid"), AUDIO("audio", "aid"), SUBTITLE("sub", "sid") }
enum class SubtitleRole(val prefix: String) { PRIMARY(""), SECONDARY("secondary-") }
/** Explicit outputs never switch. AUTOMATIC may choose or fall back to GPU for features or decoder failure. */
enum class VideoOutput(val mpvName: String) { AUTOMATIC("auto"), GPU("gpu-next"), NATIVE_SURFACE("mediacodec_embed") }
enum class HardwareDecoding(val mpvName: String) { AUTOMATIC("mediacodec,mediacodec-copy"), MEDIACODEC("mediacodec"), DISABLED("no") }
enum class HDRPolicy { AUTOMATIC, DISABLED }
/** Compatibility explicitly drops Profile 7 enhancement data and converts RPU to 8.1 on native DV displays. */
enum class DolbyVisionPolicy { STRICT, PROFILE7_COMPATIBILITY }
/** Subtitle-driven renderer selection for [VideoOutput.AUTOMATIC] only.
 * Explicit GPU and native outputs never switch. Feature requests only report availability.
 */
enum class NativeVideoFeaturePolicy { PRESERVE_DOLBY_VISION, PREFER_FEATURES }
enum class DynamicRange { UNKNOWN, SDR, HDR10, HLG, DOLBY_VISION }

data class TrackIdentifier(val type: TrackType, val mpvId: Int)
data class MediaTrack(
    val id: TrackIdentifier, val title: String? = null, val language: String? = null,
    val codec: String? = null, val isSelected: Boolean = false, val isDefault: Boolean = false,
    val isForced: Boolean = false, val isExternal: Boolean = false, val subtitleRole: SubtitleRole? = null,
    val requiresSubtitleRenderer: Boolean = id.type == TrackType.SUBTITLE,
) {
    /** The native identifier within this track's category. */
    val mpvId: Int get() = id.mpvId
    /** The track's media category. */
    val type: TrackType get() = id.type
    val label: String get() = listOfNotNull(title, language, codec).joinToString(" · ").ifEmpty { "${id.type} ${id.mpvId}" }
}
/** Chapter boundaries in seconds; the final end time can be unknown. */
data class Chapter(val id: Int, val title: String?, val startTime: Double, val endTime: Double? = null) {
    /** Nonnegative duration in seconds, when the end is known. */
    val duration: Double? get() = endTime?.let { (it - startTime).coerceAtLeast(0.0) }
}
/** Encoded dimensions, optional pixel-aspect-corrected display size, and clockwise rotation. */
data class VideoDimensions(val width: Int = 0, val height: Int = 0, val rotation: Int = 0, val displayWidth: Int? = null, val displayHeight: Int? = null) {
    val aspectRatio: Float get() {
        val w = displayWidth?.takeIf { it > 0 } ?: width
        val h = displayHeight?.takeIf { it > 0 } ?: height
        if (h <= 0 || w <= 0) return 16f / 9f
        return if (((rotation % 360) + 360) % 180 == 90) h.toFloat() / w else w.toFloat() / h
    }
}
data class VideoSignal(
    val primaries: String? = null, val transferFunction: TransferFunction = TransferFunction.UNKNOWN, val matrix: String? = null,
    val dolbyVision: Boolean = false, val signalPeak: Double? = null,
    val range: String? = null, val bitDepth: Int? = null,
    val minimumLuminance: Double? = null, val maximumLuminance: Double? = null,
    val maxContentLightLevel: Double? = null, val maxFrameAverageLightLevel: Double? = null,
    val hasHDR10PlusMetadata: Boolean? = null, val dolbyVisionProfile: Int? = null,
    val dolbyVisionBaseLayerCompatibilityID: Int? = null,
    /** Original unrecognized transfer value when [transferFunction] is [TransferFunction.OTHER]. */
    val rawTransferFunction: String? = null,
) {
    /** Whether the reported transfer function is PQ or HLG. */
    val isHDR: Boolean get() = transferFunction.isHDR
    val dynamicRange: DynamicRange get() = when {
        dolbyVision -> DynamicRange.DOLBY_VISION
        transferFunction == TransferFunction.PQ -> DynamicRange.HDR10
        transferFunction == TransferFunction.HLG -> DynamicRange.HLG
        transferFunction == TransferFunction.UNKNOWN -> DynamicRange.UNKNOWN
        else -> DynamicRange.SDR
    }
}
data class DisplayCapabilities(val hdr10: Boolean = false, val hlg: Boolean = false, val dolbyVision: Boolean = false,
    val wideGamut: Boolean = false, val refreshRate: Double? = null)
data class HDRStatus(
    val source: VideoSignal = VideoSignal(), val output: VideoSignal = VideoSignal(),
    val displayCapabilities: DisplayCapabilities = DisplayCapabilities(),
    val presentation: PresentationStatus = PresentationStatus(),
    val decoded: VideoSignal = VideoSignal(), val videoOutputInput: VideoSignal = VideoSignal(),
)
data class BufferRange(val start: Double, val end: Double)
data class BufferStatus(
    val isBuffering: Boolean = false, val progress: Double = 0.0, val secondsBufferedAhead: Double = 0.0,
    val bufferedEnd: Double? = null, val bytesAhead: Long = 0, val totalBytes: Long? = null,
    val inputRate: Long = 0, val seekableRanges: List<BufferRange> = emptyList(),
)
data class RenderPass(val name: String, val averageNanoseconds: Long?)
data class PlaybackDiagnostics(
    val videoCodec: String? = null, val audioCodec: String? = null,
    val hardwareDecoder: String? = null, val videoOutput: String? = null,
    val containerFramesPerSecond: Double? = null, val audioChannels: String? = null,
    val decoderDroppedFrames: Long? = null, val outputDroppedFrames: Long? = null,
    val mistimedFrames: Long? = null, val delayedFrames: Long? = null, val audioVideoDriftSeconds: Double? = null,
    val estimatedFilterFramesPerSecond: Double? = null, val nominalDisplayFramesPerSecond: Double? = null, val estimatedDisplayFramesPerSecond: Double? = null,
    val audioOutput: String? = null, val outputChannels: String? = null, val outputFormat: String? = null,
    val pixelFormat: String? = null, val interop: String? = null, val decoder: String? = null,
    val deinterlaceActive: Boolean? = null, val interlaced: Boolean? = null, val filters: List<String> = emptyList(),
    val effectiveOptions: Map<String, String> = emptyMap(), val renderPasses: List<RenderPass> = emptyList(),
    val startLatencySeconds: Double? = null, val seekLatencySeconds: Double? = null,
    val fallbackReasons: List<String> = emptyList(),
    val spatialAudioAvailable: Boolean? = null, val spatialAudioEnabled: Boolean? = null,
    val renderingPreset: RenderingQuality.Preset? = null,
    val unsupportedFeatures: List<String> = emptyList(),
)
/** Semantic caption text and placement; raw settings preserve unsupported authored extensions. */
data class TextSubtitleRegion(
    val text: String, val role: SubtitleRole? = SubtitleRole.PRIMARY,
    val placement: TextSubtitlePlacement = TextSubtitlePlacement.Automatic,
    val trackID: Int? = null, val rawSettings: String? = null,
)
data class TextSubtitleSnapshot(val regions: List<TextSubtitleRegion> = emptyList())
data class TimedTextSubtitleSnapshot(val startTime: Double, val endTime: Double, val snapshot: TextSubtitleSnapshot) {
    fun contains(timestamp: Double): Boolean = timestamp >= startTime && timestamp < endTime
}
/** Observable playback state, including the media information and buffer status exposed separately on Apple. */
data class PlaybackSnapshot(
    val state: PlaybackState = PlaybackState.IDLE,
    val position: Double = 0.0, val duration: Double = 0.0,
    val seekable: Boolean = false, val paused: Boolean = true,
    val volume: Double = 100.0, val muted: Boolean = false, val playbackRate: Double = 1.0,
    val title: String = "", val dimensions: VideoDimensions = VideoDimensions(),
    val hasVideoFrame: Boolean = false,
    val tracks: List<MediaTrack> = emptyList(), val chapters: List<Chapter> = emptyList(),
    val currentChapterIndex: Int? = null, val hdr: HDRStatus = HDRStatus(),
    val dolbyVision: DolbyVisionStatus = DolbyVisionStatus(),
    val metadata: Map<String, String> = emptyMap(),
    val diagnostics: PlaybackDiagnostics = PlaybackDiagnostics(),
    val isDiagnosticsEnabled: Boolean = false,
    val subtitles: TextSubtitleSnapshot = TextSubtitleSnapshot(), val error: PlayerError? = null,
    val interceptsTextSubtitles: Boolean = false,
    /** Identifies the load request that owns this snapshot. */
    val loadGeneration: Long = 0,
    val container: String? = null, val fileSize: Long? = null, val buffer: BufferStatus = BufferStatus(),
    val videoFeatureCapabilities: VideoFeatureCapabilities = VideoFeatureCapabilities(),
    val videoFeatureRequestResult: VideoFeatureRequestResult? = null,
) {
    val isPlaying: Boolean get() = state == PlaybackState.PLAYING
    val videoTracks: List<MediaTrack> get() = tracks.filter { it.id.type == TrackType.VIDEO }
    fun selectedSubtitle(role: SubtitleRole = SubtitleRole.PRIMARY): MediaTrack? =
        subtitleTracks.firstOrNull { it.isSelected && it.subtitleRole == role }
    val audioTracks: List<MediaTrack> get() = tracks.filter { it.id.type == TrackType.AUDIO }
    val subtitleTracks: List<MediaTrack> get() = tracks.filter { it.id.type == TrackType.SUBTITLE }
}

data class PlayerConfiguration(
    val autoPlay: Boolean = true, val loop: Boolean = false,
    val playbackRate: Double = 1.0, val volume: Double = 100.0, val startTime: Double? = null,
    val initialBufferSeconds: Double = 1.0, val networkCacheSeconds: Double = 10.0,
    val hardwareDecoding: HardwareDecoding = HardwareDecoding.AUTOMATIC,
    val videoOutput: VideoOutput = VideoOutput.GPU, val hdrPolicy: HDRPolicy = HDRPolicy.AUTOMATIC,
    val dolbyVisionPolicy: DolbyVisionPolicy = DolbyVisionPolicy.STRICT,
    val nativeVideoFeaturePolicy: NativeVideoFeaturePolicy = NativeVideoFeaturePolicy.PRESERVE_DOLBY_VISION,
    val deinterlace: DeinterlacePolicy = DeinterlacePolicy(),
    val renderingQuality: RenderingQuality = RenderingQuality(),
    val displayMatching: DisplayMatching = DisplayMatching.AUTOMATIC,
    val audio: AudioConfiguration = AudioConfiguration(),
    val cache: CacheConfiguration = CacheConfiguration(),
    val logLevel: LogLevel = LogLevel.WARNING, val additionalOptions: Map<String, String> = emptyMap(),
    /** Desired native HDR white / SDR white ratio. Zero uses Android's automatic headroom.
     * Explicit values must be finite and in 1..10000. Actual brightness depends on the display.
     * Applies to native output with [HDRPolicy.AUTOMATIC]; GPU output is SDR.
     */
    val desiredHDRHeadroom: Float = 0f,
) {
    init {
        require(desiredHDRHeadroom.isFinite() && (desiredHDRHeadroom == 0f || desiredHDRHeadroom in 1f..10000f)) {
            "desiredHDRHeadroom must be zero (automatic) or a finite ratio in 1..10000"
        }
    }
}
