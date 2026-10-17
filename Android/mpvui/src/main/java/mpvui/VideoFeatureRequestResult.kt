package mpvui

/** Availability of requested features on the current renderer. Requests never switch or reload it. */
data class VideoFeatureRequestResult(
    val outcome: Outcome,
    val requestedFeatures: Set<VideoFeature>,
    val unavailableFeatures: Set<VideoFeature>,
    val reason: String? = null,
) {
    /** Whether the request is satisfied, pending metadata, or unsupported. */
    enum class Outcome { AVAILABLE, AWAITING_VIDEO_METADATA, UNAVAILABLE }
}
