package mpvui

/** Ownership of Android audio focus and route-disconnection handling. */
data class AudioConfiguration(val audioSession: AudioSession = AudioSession.AUTOMATIC) {
    enum class AudioSession { AUTOMATIC, HOST_MANAGED }
}

/** Demuxer packet limits in bytes. These do not limit decoder or GPU allocations. */
data class CacheConfiguration(
    val mode: Mode = Mode.AUTOMATIC,
    val maximumBytes: Long = 64L * 1024 * 1024,
    val maximumBackBytes: Long = 16L * 1024 * 1024,
) {
    enum class Mode(val mpvName: String) { AUTOMATIC("auto"), ENABLED("yes"), DISABLED("no") }

}

/** Severity threshold and native log message level. */
enum class LogLevel(val mpvName: String) {
    NONE("no"), FATAL("fatal"), ERROR("error"), WARNING("warn"), INFO("info"), STATUS("status"),
    VERBOSE("v"), DEBUG("debug"), TRACE("trace");
    companion object {
        fun fromMPV(value: String): LogLevel = entries.firstOrNull { it.mpvName == value } ?: INFO
    }
}

data class LogMessage(val prefix: String, val level: LogLevel, val message: String)

/** Configured output and its limitations; it never asserts physical HDR presentation. */
data class PresentationStatus(
    val requestedPolicy: HDRPolicy = HDRPolicy.AUTOMATIC,
    val backend: VideoOutput? = null,
    val configuredDynamicRange: DynamicRange = DynamicRange.UNKNOWN,
    val actualDynamicRange: DynamicRange = DynamicRange.UNKNOWN,
    val fallbackReason: FallbackReason? = null,
) {
    enum class FallbackReason {
        GPU_OUTPUT_IS_SDR, DISPLAY_DOES_NOT_SUPPORT_HDR, NATIVE_OUTPUT_UNAVAILABLE, UNSUPPORTED_POLICY,
    }
}

/** Source metadata is separate from frame validation and conversion evidence. */
data class DolbyVisionStatus(
    val requestedPolicy: DolbyVisionPolicy = DolbyVisionPolicy.STRICT,
    val sourceProfile: Int? = null,
    val sourceBaseLayerCompatibilityID: Int? = null,
    val effectiveProfile: Int? = null,
    val effectiveBaseLayerCompatibilityID: Int? = null,
    val nativeValidation: NativeValidation = NativeValidation.UNKNOWN,
    val conversion: Conversion = Conversion.NOT_REQUESTED,
    val enhancementLayer: EnhancementLayer = EnhancementLayer.UNKNOWN,
    val reason: String? = null,
) {
    enum class NativeValidation { UNKNOWN, VALIDATED, REJECTED }
    enum class Conversion { NOT_REQUESTED, PENDING, CONVERTED, UNAVAILABLE }
    enum class EnhancementLayer { UNKNOWN, DISCARDED }
}

/** Typed failures; native command errors retain their code and context. */
sealed class PlayerError(open val message: String, open val code: Int = 0) {
    data object ClientUnavailable : PlayerError("The playback session is closed or unavailable")
    data object ClientCreationFailed : PlayerError("Unable to create the mpv client")
    data class InitializationFailed(val context: String, override val code: Int, override val message: String) : PlayerError(message, code)
    data class LoadFailed(override val code: Int, override val message: String) : PlayerError(message, code)
    data class PlaybackFailed(override val code: Int, override val message: String) : PlayerError(message, code)
    data class CommandFailed(val context: String, override val code: Int, override val message: String) : PlayerError(message, code)
    data class NativeVideoOutputUnavailable(override val message: String) : PlayerError(message)
    data class ReservedProperty(val name: String) : PlayerError("$name is owned by MPVUI")
    data class InvalidSubtitleTrack(val track: TrackIdentifier) : PlayerError("Choose a subtitle track from the current item")
    data object EventQueueOverflow : PlayerError("The mpv event queue overflowed; state was refreshed")
    data object PictureInPictureUnsupported : PlayerError("Picture in picture is unsupported")
    data object PictureInPictureNotReady : PlayerError("The current video is not ready for picture in picture")
    data class PictureInPictureFailed(val operation: PictureInPictureOperation, override val message: String) : PlayerError(message)
    enum class PictureInPictureOperation { START, RESTORE_INTERFACE }
}
