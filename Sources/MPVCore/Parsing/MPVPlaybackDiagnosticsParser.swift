package enum MPVPlaybackDiagnosticsParser {

    package enum VideoToolboxSessionResult {

        case hardware
        case software
        case unknown
    }

    package static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }

    package static func nonnegative(_ value: Int64?) -> Int64? {
        value.flatMap { $0 >= 0 ? $0 : nil }
    }

    package static func renderPasses(_ node: MPVNodeValue?) -> [MPVPlaybackDiagnostics.RenderPass]? {
        node?.arrayValue?.compactMap { value in
            guard let pass = value.mapValue, let name = pass["desc"]?.stringValue else { return nil }
            return .init(
                name: name,
                lastNanoseconds: nonnegative(pass["last"]?.integerValue),
                averageNanoseconds: nonnegative(pass["avg"]?.integerValue),
                peakNanoseconds: nonnegative(pass["peak"]?.integerValue)
            )
        }
    }

    package static func nativeStatistics(_ node: MPVNodeValue?) -> MPVPlaybackDiagnostics.NativeOutputStatistics? {
        guard let map = node?.mapValue else { return nil }
        return .init(
            pixelBufferCopies: nonnegative(map["pixel-buffer-copies"]?.integerValue),
            sampleBuildCount: nonnegative(map["sample-build-count"]?.integerValue),
            lastSampleBuildNanoseconds: nonnegative(map["last-sample-build-ns"]?.integerValue),
            totalSampleBuildNanoseconds: nonnegative(map["total-sample-build-ns"]?.integerValue)
        )
    }

    package static func videoToolboxSession(_ log: MPVLogMessage) -> VideoToolboxSessionResult? {
        guard log.prefix == "ffmpeg/video",
              let payload = MPVNativeDiagnosticParser.payload(log, sentinel: "MPVUI_VIDEOTOOLBOX_SESSION:", allowsDecoder: true)
        else { return nil }
        let fields = payload.split(whereSeparator: \.isWhitespace)
        if fields.contains("hardware=yes") {
            return .hardware
        }
        if fields.contains("hardware=no") {
            return .software
        }
        if fields.contains("hardware=unknown") {
            return .unknown
        }
        return nil
    }

    package static func decoder(
        codec: String?,
        hardwareDecoder: String?,
        interop: String?,
        pixelFormat: String?,
        requested: MPVHardwareDecoding,
        sessionUsesHardware: Bool? = nil,
        codecSupportsHardware: Bool? = nil
    ) -> MPVPlaybackDiagnostics.Decoder {
        var result = MPVPlaybackDiagnostics.Decoder()
        result.codec = codec
        result.selectedDecoder = hardwareDecoder
        result.videoToolboxSessionUsesHardware = hardwareDecoder?.hasPrefix("videotoolbox") == true ? sessionUsesHardware : nil
        result.videoToolboxSupportsCodec = codecSupportsHardware
        result.interop = interop
        result.decodedPixelFormat = pixelFormat
        if let hardwareDecoder, !hardwareDecoder.isEmpty {
            if hardwareDecoder == "no" || sessionUsesHardware == false {
                result.session = .software
                if requested != .disabled {
                    result.fallbackReason = hardwareDecoder == "no"
                        ? """
                        mpv selected software decoding for this item; the codec-level hardware probe does not validate this profile, \
                        bit depth or resolution.
                        """
                        : "VideoToolbox created a software decoding session for this item."
                }
            } else if sessionUsesHardware == true {
                result.session = .hardware(hardwareDecoder)
            }
        }
        return result
    }
}
