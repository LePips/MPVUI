package mpvui.internal

import mpvui.*
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** ABI v1 domain records. This codec performs no playback or native-property interpretation. */
internal object CoreWire {
    private val header = byteArrayOf(77, 80, 86, 67, 1, 0, 0, 0)
    fun encode(value: Any?): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(header)
        fun scalar(value: Long, bytes: Int) { repeat(bytes) { output.write((value ushr (it * 8)).toInt() and 255) } }
        fun write(value: Any?) {
            when (value) {
                null -> output.write(0)
                is Boolean -> output.write(if (value) 2 else 1)
                is Byte, is Short, is Int, is Long -> { output.write(3); scalar((value as Number).toLong(), 8) }
                is Float, is Double -> {
                    val number = (value as Number).toDouble()
                    if (!number.isFinite()) output.write(0) else { output.write(4); scalar(number.toBits(), 8) }
                }
                is String -> { val bytes = value.toByteArray(Charsets.UTF_8); output.write(5); scalar(bytes.size.toLong(), 4); output.write(bytes) }
                is List<*> -> { output.write(6); scalar(value.size.toLong(), 4); value.forEach(::write) }
                is Map<*, *> -> { output.write(7); scalar(value.size.toLong(), 4); value.forEach { (key, item) -> require(key is String); write(key); write(item) } }
                else -> error("Unsupported core record value")
            }
        }
        write(value)
        return output.toByteArray()
    }
    fun decode(bytes: ByteArray): Any? {
        require(bytes.size in 9..(32 * 1024 * 1024) && bytes.copyOfRange(0, 8).contentEquals(header)) { "Unsupported core ABI record" }
        val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).apply { position(8) }
        fun count(): Int = input.int.also { require(it >= 0 && it <= input.remaining()) }
        fun read(depth: Int): Any? {
            require(depth < 32 && input.hasRemaining())
            return when (input.get().toInt()) {
                0 -> null
                1 -> false
                2 -> true
                3 -> input.long
                4 -> input.double.also { require(it.isFinite()) }
                5 -> ByteArray(count()).also(input::get).toString(Charsets.UTF_8)
                6 -> List(count()) { read(depth + 1) }
                7 -> buildMap<String, Any?> {
                    repeat(count()) { val key = read(depth + 1) as String; require(!containsKey(key)); put(key, read(depth + 1)) }
                }
                else -> error("Invalid core ABI tag")
            }
        }
        return read(0).also { require(!input.hasRemaining()) }
    }
    internal class Record(value: Any?) {
        private val fields = value as? Map<*, *> ?: emptyMap<Any, Any>()
        fun value(key: String): Any? = fields[key]
        fun text(key: String): String? = fields[key] as? String
        fun number(key: String): Number? = fields[key] as? Number
        fun flag(key: String): Boolean? = fields[key] as? Boolean
        fun list(key: String): List<*> = fields[key] as? List<*> ?: emptyList<Any>()
        fun strings(key: String): Map<String, String> = (fields[key] as? Map<*, *>)?.entries?.associate { it.key as String to it.value as String } ?: emptyMap()
        inline fun <reified T : Enum<T>> enumeration(key: String): T? = text(key)?.let { enumValueOf<T>(it) }
    }
    fun snapshot(bytes: ByteArray): PlaybackSnapshot = playbackSnapshot(decode(bytes))
    fun log(bytes: ByteArray): LogMessage = Record(decode(bytes)).let { LogMessage(it.text("prefix").orEmpty(), LogLevel.fromMPV(it.text("level").orEmpty()), it.text("message").orEmpty()) }
    fun timeline(bytes: ByteArray): List<TimedTextSubtitleSnapshot> = (decode(bytes) as List<*>).map(::timedTextSubtitleSnapshot)
    private fun textSubtitleSnapshot(value: Any?): TextSubtitleSnapshot = TextSubtitleSnapshot((value as? List<*>)?.map(::textSubtitleRegion) ?: emptyList())
    private fun placement(value: Any?): TextSubtitlePlacement = if (value == null) TextSubtitlePlacement.Automatic else TextSubtitlePlacement.WebVTT(webVTTPlacement(value))
    fun failure(value: Any?): PlayerError? {
        if (value == null) return null
        val r = Record(value); val message = r.text("message").orEmpty(); val code = r.number("code")?.toInt() ?: 0
        return when (r.text("type")) {
            "clientCreationFailed" -> PlayerError.ClientCreationFailed
            "clientUnavailable" -> PlayerError.ClientUnavailable
            "initializationFailed" -> PlayerError.InitializationFailed(r.text("context").orEmpty(), code, message)
            "loadFailed" -> PlayerError.LoadFailed(code, message)
            "playbackFailed" -> PlayerError.PlaybackFailed(code, message)
            "commandFailed" -> PlayerError.CommandFailed(r.text("context").orEmpty(), code, message)
            "nativeVideoOutputUnavailable" -> PlayerError.NativeVideoOutputUnavailable(message)
            "reservedProperty" -> PlayerError.ReservedProperty(r.text("name").orEmpty())
            "invalidSubtitleTrack" -> PlayerError.InvalidSubtitleTrack(trackIdentifier(r.value("track")))
            "eventQueueOverflow" -> PlayerError.EventQueueOverflow
            else -> PlayerError.CommandFailed("Platform", code, message)
        }
    }
    private fun playbackSnapshot(value: Any?): PlaybackSnapshot {
        val r = Record(value)
        return PlaybackSnapshot(
            state = r.enumeration<PlaybackState>("state") ?: PlaybackState.IDLE,
            position = r.number("position")?.toDouble() ?: 0.0,
            duration = r.number("duration")?.toDouble() ?: 0.0,
            seekable = r.flag("seekable") ?: false,
            paused = r.flag("paused") ?: true,
            volume = r.number("volume")?.toDouble() ?: 100.0,
            muted = r.flag("muted") ?: false,
            playbackRate = r.number("playbackRate")?.toDouble() ?: 1.0,
            title = r.text("title") ?: "",
            dimensions = videoDimensions(r.value("dimensions")),
            hasVideoFrame = r.flag("hasVideoFrame") ?: false,
            tracks = r.list("tracks").map { mediaTrack(it) },
            chapters = r.list("chapters").map { chapter(it) },
            currentChapterIndex = r.number("currentChapterIndex")?.toInt(),
            hdr = hDRStatus(r.value("hdr")),
            dolbyVision = dolbyVisionStatus(r.value("dolbyVision")),
            metadata = r.strings("metadata"),
            diagnostics = playbackDiagnostics(r.value("diagnostics")),
            isDiagnosticsEnabled = r.flag("isDiagnosticsEnabled") ?: false,
            subtitles = textSubtitleSnapshot(r.value("subtitles")),
            error = failure(r.value("error")),
            interceptsTextSubtitles = r.flag("interceptsTextSubtitles") ?: false,
            loadGeneration = r.number("loadGeneration")?.toLong() ?: 0,
            container = r.text("container"),
            fileSize = r.number("fileSize")?.toLong(),
            buffer = bufferStatus(r.value("buffer")),
            videoFeatureCapabilities = featureCapabilities(r.value("videoFeatureCapabilities")),
            videoFeatureRequestResult = featureRequestResult(r.value("videoFeatureRequestResult")),
        )
    }
    private fun featureCapabilities(value: Any?): VideoFeatureCapabilities {
        val record = Record(value)
        val features = Record(record.value("features"))
        return VideoFeatureCapabilities(record.enumeration<VideoOutput>("backend"), record.flag("hasVideo") ?: false,
            VideoFeature.entries.associateWith { feature ->
                val capability = Record(features.value(feature.name))
                VideoFeatureCapabilities.Capability(capability.enumeration<VideoFeatureCapabilities.Availability>("availability")
                    ?: VideoFeatureCapabilities.Availability.UNKNOWN, capability.enumeration<VideoFeatureCapabilities.Restriction>("restriction"))
            })
    }
    fun featureRequestResult(value: Any?): VideoFeatureRequestResult? {
        if (value == null) return null
        val record = Record(value)
        return VideoFeatureRequestResult(requireNotNull(record.enumeration<VideoFeatureRequestResult.Outcome>("outcome")),
            record.list("requestedFeatures").map { VideoFeature.valueOf(it as String) }.toSet(),
            record.list("unavailableFeatures").map { VideoFeature.valueOf(it as String) }.toSet(), record.text("reason"))
    }
    private fun trackIdentifier(value: Any?): TrackIdentifier {
        val r = Record(value)
        return TrackIdentifier(
            type = requireNotNull(r.enumeration<TrackType>("type")),
            mpvId = requireNotNull(r.number("mpvId")?.toInt()),
        )
    }
    private fun mediaTrack(value: Any?): MediaTrack {
        val r = Record(value)
        return MediaTrack(
            id = trackIdentifier(r.value("id")),
            title = r.text("title"),
            language = r.text("language"),
            codec = r.text("codec"),
            isSelected = r.flag("isSelected") ?: false,
            isDefault = r.flag("isDefault") ?: false,
            isForced = r.flag("isForced") ?: false,
            isExternal = r.flag("isExternal") ?: false,
            subtitleRole = r.enumeration<SubtitleRole>("subtitleRole"),
            requiresSubtitleRenderer = r.flag("requiresSubtitleRenderer") ?: false,
        )
    }
    private fun chapter(value: Any?): Chapter {
        val r = Record(value)
        return Chapter(
            id = requireNotNull(r.number("id")?.toInt()),
            title = r.text("title"),
            startTime = requireNotNull(r.number("startTime")?.toDouble()),
            endTime = r.number("endTime")?.toDouble(),
        )
    }
    private fun videoDimensions(value: Any?): VideoDimensions {
        val r = Record(value)
        return VideoDimensions(
            width = r.number("width")?.toInt() ?: 0,
            height = r.number("height")?.toInt() ?: 0,
            rotation = r.number("rotation")?.toInt() ?: 0,
            displayWidth = r.number("displayWidth")?.toInt(),
            displayHeight = r.number("displayHeight")?.toInt(),
        )
    }
    private fun videoSignal(value: Any?): VideoSignal {
        val r = Record(value)
        return VideoSignal(
            primaries = r.text("primaries"),
            transferFunction = r.enumeration<TransferFunction>("transferFunction") ?: TransferFunction.UNKNOWN,
            matrix = r.text("matrix"),
            dolbyVision = r.flag("dolbyVision") ?: false,
            signalPeak = r.number("signalPeak")?.toDouble(),
            range = r.text("range"),
            bitDepth = r.number("bitDepth")?.toInt(),
            minimumLuminance = r.number("minimumLuminance")?.toDouble(),
            maximumLuminance = r.number("maximumLuminance")?.toDouble(),
            maxContentLightLevel = r.number("maxContentLightLevel")?.toDouble(),
            maxFrameAverageLightLevel = r.number("maxFrameAverageLightLevel")?.toDouble(),
            hasHDR10PlusMetadata = r.flag("hasHDR10PlusMetadata"),
            dolbyVisionProfile = r.number("dolbyVisionProfile")?.toInt(),
            dolbyVisionBaseLayerCompatibilityID = r.number("dolbyVisionBaseLayerCompatibilityID")?.toInt(),
            rawTransferFunction = r.text("rawTransferFunction"),
        )
    }
    private fun displayCapabilities(value: Any?): DisplayCapabilities {
        val r = Record(value)
        return DisplayCapabilities(
            hdr10 = r.flag("hdr10") ?: false,
            hlg = r.flag("hlg") ?: false,
            dolbyVision = r.flag("dolbyVision") ?: false,
            wideGamut = r.flag("wideGamut") ?: false,
            refreshRate = r.number("refreshRate")?.toDouble(),
        )
    }
    private fun hDRStatus(value: Any?): HDRStatus {
        val r = Record(value)
        return HDRStatus(
            source = videoSignal(r.value("source")),
            output = videoSignal(r.value("output")),
            displayCapabilities = displayCapabilities(r.value("displayCapabilities")),
            presentation = presentationStatus(r.value("presentation")),
            decoded = videoSignal(r.value("decoded")),
            videoOutputInput = videoSignal(r.value("videoOutputInput")),
        )
    }
    private fun bufferRange(value: Any?): BufferRange {
        val r = Record(value)
        return BufferRange(
            start = requireNotNull(r.number("start")?.toDouble()),
            end = requireNotNull(r.number("end")?.toDouble()),
        )
    }
    private fun bufferStatus(value: Any?): BufferStatus {
        val r = Record(value)
        return BufferStatus(
            isBuffering = r.flag("isBuffering") ?: false,
            progress = r.number("progress")?.toDouble() ?: 0.0,
            secondsBufferedAhead = r.number("secondsBufferedAhead")?.toDouble() ?: 0.0,
            bufferedEnd = r.number("bufferedEnd")?.toDouble(),
            bytesAhead = r.number("bytesAhead")?.toLong() ?: 0,
            totalBytes = r.number("totalBytes")?.toLong(),
            inputRate = r.number("inputRate")?.toLong() ?: 0,
            seekableRanges = r.list("seekableRanges").map { bufferRange(it) },
        )
    }
    private fun renderPass(value: Any?): RenderPass {
        val r = Record(value)
        return RenderPass(
            name = requireNotNull(r.text("name")),
            averageNanoseconds = r.number("averageNanoseconds")?.toLong(),
        )
    }
    private fun playbackDiagnostics(value: Any?): PlaybackDiagnostics {
        val r = Record(value)
        return PlaybackDiagnostics(
            videoCodec = r.text("videoCodec"),
            audioCodec = r.text("audioCodec"),
            hardwareDecoder = r.text("hardwareDecoder"),
            videoOutput = r.text("videoOutput"),
            containerFramesPerSecond = r.number("containerFramesPerSecond")?.toDouble(),
            audioChannels = r.text("audioChannels"),
            decoderDroppedFrames = r.number("decoderDroppedFrames")?.toLong(),
            outputDroppedFrames = r.number("outputDroppedFrames")?.toLong(),
            mistimedFrames = r.number("mistimedFrames")?.toLong(),
            delayedFrames = r.number("delayedFrames")?.toLong(),
            audioVideoDriftSeconds = r.number("audioVideoDriftSeconds")?.toDouble(),
            estimatedFilterFramesPerSecond = r.number("estimatedFilterFramesPerSecond")?.toDouble(),
            nominalDisplayFramesPerSecond = r.number("nominalDisplayFramesPerSecond")?.toDouble(),
            estimatedDisplayFramesPerSecond = r.number("estimatedDisplayFramesPerSecond")?.toDouble(),
            audioOutput = r.text("audioOutput"),
            outputChannels = r.text("outputChannels"),
            outputFormat = r.text("outputFormat"),
            pixelFormat = r.text("pixelFormat"),
            interop = r.text("interop"),
            decoder = r.text("decoder"),
            deinterlaceActive = r.flag("deinterlaceActive"),
            interlaced = r.flag("interlaced"),
            filters = r.list("filters").map { it as String },
            effectiveOptions = r.strings("effectiveOptions"),
            renderPasses = r.list("renderPasses").map { renderPass(it) },
            startLatencySeconds = r.number("startLatencySeconds")?.toDouble(),
            seekLatencySeconds = r.number("seekLatencySeconds")?.toDouble(),
            fallbackReasons = r.list("fallbackReasons").map { it as String },
            spatialAudioAvailable = r.flag("spatialAudioAvailable"),
            spatialAudioEnabled = r.flag("spatialAudioEnabled"),
            renderingPreset = r.enumeration<RenderingQuality.Preset>("renderingPreset"),
            unsupportedFeatures = r.list("unsupportedFeatures").map { it as String },
        )
    }
    private fun textSubtitleRegion(value: Any?): TextSubtitleRegion {
        val r = Record(value)
        return TextSubtitleRegion(
            text = requireNotNull(r.text("text")),
            role = r.enumeration<SubtitleRole>("role") ?: SubtitleRole.PRIMARY,
            placement = placement(r.value("placement")),
            trackID = r.number("trackID")?.toInt(),
            rawSettings = r.text("rawSettings"),
        )
    }
    private fun timedTextSubtitleSnapshot(value: Any?): TimedTextSubtitleSnapshot {
        val r = Record(value)
        return TimedTextSubtitleSnapshot(
            startTime = requireNotNull(r.number("startTime")?.toDouble()),
            endTime = requireNotNull(r.number("endTime")?.toDouble()),
            snapshot = textSubtitleSnapshot(r.value("snapshot")),
        )
    }
    private fun presentationStatus(value: Any?): PresentationStatus {
        val r = Record(value)
        return PresentationStatus(
            requestedPolicy = r.enumeration<HDRPolicy>("requestedPolicy") ?: HDRPolicy.AUTOMATIC,
            backend = r.enumeration<VideoOutput>("backend"),
            configuredDynamicRange = r.enumeration<DynamicRange>("configuredDynamicRange") ?: DynamicRange.UNKNOWN,
            actualDynamicRange = r.enumeration<DynamicRange>("actualDynamicRange") ?: DynamicRange.UNKNOWN,
            fallbackReason = r.enumeration<PresentationStatus.FallbackReason>("fallbackReason"),
        )
    }
    private fun dolbyVisionStatus(value: Any?): DolbyVisionStatus {
        val r = Record(value)
        return DolbyVisionStatus(
            requestedPolicy = r.enumeration<DolbyVisionPolicy>("requestedPolicy") ?: DolbyVisionPolicy.STRICT,
            sourceProfile = r.number("sourceProfile")?.toInt(),
            sourceBaseLayerCompatibilityID = r.number("sourceBaseLayerCompatibilityID")?.toInt(),
            effectiveProfile = r.number("effectiveProfile")?.toInt(),
            effectiveBaseLayerCompatibilityID = r.number("effectiveBaseLayerCompatibilityID")?.toInt(),
            nativeValidation = r.enumeration<DolbyVisionStatus.NativeValidation>("nativeValidation") ?: DolbyVisionStatus.NativeValidation.UNKNOWN,
            conversion = r.enumeration<DolbyVisionStatus.Conversion>("conversion") ?: DolbyVisionStatus.Conversion.NOT_REQUESTED,
            enhancementLayer = r.enumeration<DolbyVisionStatus.EnhancementLayer>("enhancementLayer") ?: DolbyVisionStatus.EnhancementLayer.UNKNOWN,
            reason = r.text("reason"),
        )
    }
    private fun webVTTPlacement(value: Any?): WebVTTPlacement {
        val r = Record(value)
        return WebVTTPlacement(
            horizontalPosition = requireNotNull(r.number("horizontalPosition")?.toFloat()),
            verticalPosition = requireNotNull(r.number("verticalPosition")?.toFloat()),
            horizontalAnchor = r.enumeration<WebVTTPlacement.HorizontalAnchor>("horizontalAnchor") ?: WebVTTPlacement.HorizontalAnchor.CENTER,
            verticalAnchor = r.enumeration<WebVTTPlacement.VerticalAnchor>("verticalAnchor") ?: WebVTTPlacement.VerticalAnchor.BOTTOM,
            maximumWidth = r.number("maximumWidth")?.toFloat(),
            maximumHeight = r.number("maximumHeight")?.toFloat(),
            textAlignment = r.enumeration<WebVTTPlacement.TextAlignment>("textAlignment") ?: WebVTTPlacement.TextAlignment.CENTER,
            writingDirection = r.enumeration<WebVTTPlacement.WritingDirection>("writingDirection") ?: WebVTTPlacement.WritingDirection.HORIZONTAL,
        )
    }
}
