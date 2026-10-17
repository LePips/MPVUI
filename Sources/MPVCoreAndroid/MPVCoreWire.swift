import CMPV
import Foundation
import MPVCore

// ABI v1 records use little-endian lengths and scalar bits, real UTF-8, and
// explicit nulls. These are copied domain DTOs, never native property nodes.
// Tags: null=0, false=1, true=2, int64=3, float64=4, string=5, list=6, record=7.
// Collections and strings carry a UInt32 count. Records carry UTF-8 field names.
indirect enum CoreValue {

    case null
    case flag(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case list([CoreValue])
    case record([String: CoreValue])

    var isRecord: Bool {
        if case .record = self {
            true
        } else {
            false
        }
    }

    var fields: [String: CoreValue] {
        if case let .record(value) = self {
            value
        } else {
            [:]
        }
    }

    var text: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    var int: Int64? {
        if case let .integer(value) = self {
            value
        } else {
            nil
        }
    }

    var double: Double? {
        switch self { case let .number(value): value
        case let .integer(value): Double(value)
        default: nil }
    }

    var bool: Bool? {
        if case let .flag(value) = self {
            value
        } else {
            nil
        }
    }

    var items: [Self] {
        if case let .list(value) = self {
            value
        } else {
            []
        }
    }

    static func value(_ value: String?) -> Self {
        value.map(string) ?? .null
    }

    static func value(_ value: Bool?) -> Self {
        value.map(flag) ?? .null
    }

    static func value(_ value: Int?) -> Self {
        value.map { .integer(Int64($0)) } ?? .null
    }

    static func value(_ value: Int64?) -> Self {
        value.map(integer) ?? .null
    }

    static func value(_ value: Double?) -> Self {
        value.flatMap { $0.isFinite ? .number($0) : nil } ?? .null
    }

    static func strings(_ values: [String: String]) -> Self {
        .record(values.mapValues(string))
    }

    static func decode(_ bytes: UnsafeBufferPointer<UInt8>) throws -> Self {
        struct InvalidRecord: Error {}
        guard bytes.count <= 32 * 1024 * 1024, bytes.count >= 9,
              Array(bytes.prefix(8)) == [77, 80, 86, 67, 1, 0, 0, 0] else { throw InvalidRecord() }
        var offset = 8
        func scalar<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let count = MemoryLayout<T>.size
            guard offset <= bytes.count - count else { throw InvalidRecord() }
            var value: T = 0
            for index in 0 ..< count {
                value |= T(truncatingIfNeeded: bytes[offset + index]) << (index * 8)
            }
            offset += count
            return value
        }
        func read(_ depth: Int) throws -> Self {
            guard depth < 32, offset < bytes.count else { throw InvalidRecord() }
            let tag = bytes[offset]
            offset += 1
            switch tag {
            case 0: return .null
            case 1, 2: return .flag(tag == 2)
            case 3: return try .integer(scalar(Int64.self))
            case 4:
                let number = try Double(bitPattern: scalar(UInt64.self))
                guard number.isFinite else { throw InvalidRecord() }
                return .number(number)
            case 5:
                let length = try Int(scalar(UInt32.self))
                guard length <= bytes.count - offset,
                      let string = String(bytes: bytes[offset ..< (offset + length)], encoding: .utf8)
                else { throw InvalidRecord() }
                offset += length
                return .string(string)
            case 6, 7:
                let count = try Int(scalar(UInt32.self))
                guard count <= bytes.count - offset else { throw InvalidRecord() }
                if tag == 6 {
                    return try .list((0 ..< count).map { _ in try read(depth + 1) })
                }
                var fields: [String: Self] = [:]
                for _ in 0 ..< count {
                    guard let key = try read(depth + 1).text, fields[key] == nil else { throw InvalidRecord() }
                    fields[key] = try read(depth + 1)
                }
                return .record(fields)
            default: throw InvalidRecord()
            }
        }
        let result = try read(0)
        guard offset == bytes.count else { throw InvalidRecord() }
        return result
    }

    func encoded() -> [UInt8] {
        var output: [UInt8] = [77, 80, 86, 67, 1, 0, 0, 0]
        append(to: &output)
        return output
    }

    func ownedBuffer() -> MPVCoreBuffer {
        let bytes = encoded()
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        pointer.initialize(from: bytes, count: bytes.count)
        return .init(data: pointer, length: bytes.count)
    }

    private func append(to output: inout [UInt8]) {
        func scalar(_ value: some FixedWidthInteger) {
            var bits = value.littleEndian
            withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
        }
        switch self {
        case .null: output.append(0)
        case let .flag(value): output.append(value ? 2 : 1)
        case let .integer(value): output.append(3)
            scalar(value)
        case let .number(value):
            if value.isFinite {
                output.append(4)
                scalar(value.bitPattern)
            } else {
                output.append(0)
            }
        case let .string(value):
            output.append(5)
            scalar(UInt32(value.utf8.count))
            output.append(contentsOf: value.utf8)
        case let .list(values):
            output.append(6)
            scalar(UInt32(values.count))
            for value in values {
                value.append(to: &output)
            }
        case let .record(fields):
            output.append(7)
            scalar(UInt32(fields.count))
            for key in fields.keys.sorted() {
                Self.string(key).append(to: &output)
                fields[key]!.append(to: &output)
            }
        }
    }
}

extension CoreValue {

    static func subtitles(_ snapshot: TextSubtitleSnapshot) -> Self {
        .list(snapshot.regions.map { region in
            var placement: Self = .null
            if case let .webVTT(value) = region.placement {
                placement = .record([
                    "horizontalPosition": .number(Double(value.horizontalPosition)),
                    "verticalPosition": .number(Double(value.verticalPosition)),
                    "horizontalAnchor": .string(value.horizontalAnchor == .center ? "CENTER" : value
                        .horizontalAnchor == .left ? "LEFT" : "RIGHT"),
                    "verticalAnchor": .string(value.verticalAnchor == .center ? "CENTER" : value.verticalAnchor == .top ? "TOP" : "BOTTOM"),
                    "maximumWidth": .value(value.maximumWidth.map(Double.init)),
                    "maximumHeight": .value(value.maximumHeight.map(Double.init)),
                    "textAlignment": .string(value.textAlignment == .center ? "CENTER" : value.textAlignment == .left ? "LEFT" : "RIGHT"),
                    "writingDirection": .string(value.writingDirection == .horizontal ? "HORIZONTAL" : value
                        .writingDirection == .verticalGrowingLeft ? "VERTICAL_GROWING_LEFT" : "VERTICAL_GROWING_RIGHT"),
                ])
            }
            return .record([
                "text": .string(region.text),
                "trackID": .value(region.trackID?.mpvID),
                "role": .value(region.role.map { $0 == .primary ? "PRIMARY" : "SECONDARY" }),
                "placement": placement
            ])
        })
    }

    static func timeline(_ values: [TimedTextSubtitleSnapshot]) -> Self {
        .list(values.map { .record([
            "startTime": .number($0.startTime.seconds),
            "endTime": .number($0.endTime.seconds),
            "snapshot": .subtitles($0.snapshot)
        ]) })
    }

    static func signal(_ value: MPVVideoSignal) -> Self {
        let transfer: String = switch value.transferFunction {
        case .unknown: "UNKNOWN"
        case .bt709: "BT709"
        case .bt1886: "BT1886"
        case .sRGB: "SRGB"
        case .linear: "LINEAR"
        case .gamma18: "GAMMA18"
        case .gamma20: "GAMMA20"
        case .gamma22: "GAMMA22"
        case .gamma24: "GAMMA24"
        case .gamma26: "GAMMA26"
        case .gamma28: "GAMMA28"
        case .pq: "PQ"
        case .hlg: "HLG"
        case .other: "OTHER"
        }
        return .record([
            "primaries": .value(value.primaries),
            "transferFunction": .string(transfer),
            "rawTransferFunction": .value(value.transferFunction.mpvValue),
            "matrix": .value(value.matrix),
            "range": .value(value.range),
            "bitDepth": .value(value.bitDepth),
            "signalPeak": .value(value.signalPeak),
            "minimumLuminance": .value(value.minimumLuminance),
            "maximumLuminance": .value(value.maximumLuminance),
            "maxContentLightLevel": .value(value.maxContentLightLevel),
            "maxFrameAverageLightLevel": .value(value.maxFrameAverageLightLevel),
            "hasHDR10PlusMetadata": .value(value.hasHDR10PlusMetadata),
            "dolbyVisionProfile": .value(value.dolbyVisionProfile),
            "dolbyVisionBaseLayerCompatibilityID": .value(value.dolbyVisionBaseLayerCompatibilityID),
            "dolbyVision": .flag(value.hasDolbyVisionMetadata),
        ])
    }

    static func failure(_ error: MPVPlayerError?) -> Self {
        guard let error else { return .null }
        var fields: [String: Self] = ["message": .string(error.localizedDescription)]
        switch error {
        case .clientCreationFailed: fields["type"] = .string("clientCreationFailed")
        case .clientUnavailable: fields["type"] = .string("clientUnavailable")
        case let .initializationFailed(context, code, _): fields.merge([
                "type": .string("initializationFailed"),
                "context": .string(context),
                "code": .integer(Int64(code))
            ]) { _, new in new }
        case let .loadFailed(code, _): fields.merge(["type": .string("loadFailed"), "code": .integer(Int64(code))]) { _, new in new }
        case let .playbackFailed(code, _): fields
            .merge(["type": .string("playbackFailed"), "code": .integer(Int64(code))]) { _, new in new }
        case let .commandFailed(context, code, _): fields.merge([
                "type": .string("commandFailed"),
                "context": .string(context),
                "code": .integer(Int64(code))
            ]) { _, new in new }
        case .nativeVideoOutputUnavailable: fields["type"] = .string("nativeVideoOutputUnavailable")
        case let .reservedProperty(name): fields["type"] = .string("reservedProperty")
            fields["name"] = .string(MPVOptionOwnership.normalizedProperty(name))
        case let .invalidSubtitleTrack(track): fields["type"] = .string("invalidSubtitleTrack")
            fields["track"] = .identifier(track)
        case .eventQueueOverflow: fields["type"] = .string("eventQueueOverflow")
        default: fields["type"] = .string("platformFailure")
        }
        return .record(fields)
    }

    static func identifier(_ id: MPVMediaTrackIdentifier) -> Self {
        .record([
            "type": .string(id.type == .video ? "VIDEO" : id.type == .audio ? "AUDIO" : "SUBTITLE"),
            "mpvId": .integer(Int64(id.mpvID))
        ])
    }

    static func snapshot(_ value: MPVSessionSnapshot) -> Self {
        let media = value.mediaInformation
        let diagnostics = value.diagnostics
        let buffer = value.buffer
        let dovi = value.dolbyVision
        let state: String = switch value.state {
        case .idle: "IDLE"
        case .loading: "LOADING"
        case .ready: "READY"
        case .playing: "PLAYING"
        case .paused: "PAUSED"
        case .buffering: "BUFFERING"
        case .seeking: "SEEKING"
        case .ended: "ENDED"
        case .stopped: "STOPPED"
        case .failed: "FAILED"
        }
        var result: [String: Self] = [
            "state": .string(state),
            "position": .number(value.position.seconds),
            "duration": .number(value.duration.seconds),
            "seekable": .flag(value.isSeekable),
            "paused": .flag(value.isPaused),
            "hasVideoFrame": .flag(value.hasVideoFrame),
            "volume": .number(value.volume),
            "muted": .flag(value.isMuted),
            "playbackRate": .number(value.playbackRate),
            "title": .string(media.title ?? ""),
            "loadGeneration": .integer(Int64(bitPattern: value.generation)),
            "isClosed": .flag(value.isClosed),
            "currentChapterIndex": .value(value.currentChapterIndex),
            "container": .value(media.container),
            "fileSize": .value(media.fileSize),
            "metadata": .strings(media.metadata),
            "isDiagnosticsEnabled": .flag(value.isDiagnosticsEnabled),
            "interceptsTextSubtitles": .flag(value.interceptsTextSubtitles),
            "subtitles": .subtitles(value.subtitles),
            "error": .failure(value.error),
        ]
        let dimensions = media.dimensions ?? .empty
        result["dimensions"] = .record([
            "width": .value(dimensions.width),
            "height": .value(dimensions.height),
            "rotation": .value(media.rotation),
            "displayWidth": .value(dimensions.displayWidth),
            "displayHeight": .value(dimensions.displayHeight)
        ])
        result["tracks"] = .list(media.tracks.map { track in .record([
            "id": .identifier(track.id),
            "title": .value(track.title),
            "language": .value(track.language),
            "codec": .value(track.codec),
            "isSelected": .flag(track.isSelected),
            "isDefault": .flag(track.isDefault),
            "isForced": .flag(track.isForced),
            "isExternal": .flag(track.isExternal),
            "requiresSubtitleRenderer": .flag(track.requiresSubtitleRenderer),
            "subtitleRole": .value(track.subtitleRole.map { $0 == .primary ? "PRIMARY" : "SECONDARY" }),
        ]) })
        result["chapters"] = .list(media.chapters.map { .record([
            "id": .value($0.id),
            "title": .value($0.title),
            "startTime": .number($0.startTime.seconds),
            "endTime": .value($0.endTime?.seconds)
        ]) })
        result["buffer"] = .record([
            "isBuffering": .flag(buffer.isBuffering),
            "progress": .number(buffer.progress),
            "secondsBufferedAhead": .number(buffer.secondsBufferedAhead.seconds),
            "bufferedEnd": .value(buffer.bufferedEnd?.seconds),
            "bytesAhead": .integer(buffer.bytesAhead),
            "totalBytes": .value(buffer.totalBytes),
            "inputRate": .integer(buffer.inputRate),
            "seekableRanges": .list(buffer.seekableRanges.map { .record([
                "start": .number($0.lowerBound.seconds),
                "end": .number($0.upperBound.seconds)
            ]) }),
        ])
        result["dolbyVision"] = .record([
            "requestedPolicy": .string(dovi.requestedPolicy == .strict ? "STRICT" : "PROFILE7_COMPATIBILITY"),
            "sourceProfile": .value(dovi.sourceProfile),
            "sourceBaseLayerCompatibilityID": .value(dovi.sourceBaseLayerCompatibilityID),
            "effectiveProfile": .value(dovi.effectiveProfile),
            "effectiveBaseLayerCompatibilityID": .value(dovi.effectiveBaseLayerCompatibilityID),
            "nativeValidation": .string(dovi.nativeValidation.rawValue.uppercased()),
            "conversion": .string(dovi.conversion == .notRequested ? "NOT_REQUESTED" : dovi.conversion.rawValue.uppercased()),
            "enhancementLayer": .string(dovi.enhancementLayer.rawValue.uppercased()),
            "reason": .value(dovi.reason),
        ])
        let presentation = media.hdr.presentation
        result["hdr"] = .record([
            "source": .signal(media.hdr.source),
            "decoded": .signal(media.hdr.decoded),
            "videoOutputInput": .signal(media.hdr.videoOutputInput),
            "output": .signal(media.hdr.output),
            "displayCapabilities": .record([
                "wideGamut": .value(media.hdr.displayCapabilities.supportsWideGamut),
                "hdr10": .value(media.hdr.displayCapabilities.supportsHDR10),
                "hlg": .value(media.hdr.displayCapabilities.supportsHLG),
                "dolbyVision": .value(media.hdr.displayCapabilities.supportsDolbyVision),
                "refreshRate": .value(media.hdr.displayCapabilities.refreshRate)
            ]),
            "presentation": .record([
                "requestedPolicy": .string(presentation.requestedPolicy == .disabled ? "DISABLED" : "AUTOMATIC"),
                "backend": .string(presentation.backend == .nativeSurface ? "NATIVE_SURFACE" : "GPU"),
                "configuredDynamicRange": .string(presentation.configuredDynamicRange == .sdr ? "SDR" : "UNKNOWN"),
                "actualDynamicRange": .string("UNKNOWN"),
            ]),
        ])
        result["diagnostics"] = .record([
            "videoCodec": .value(media.videoCodec),
            "audioCodec": .value(media.audioCodec),
            "hardwareDecoder": .value(media.hardwareDecoder),
            "videoOutput": .value(value.nativeVideoOutput),
            "containerFramesPerSecond": .value(diagnostics.containerFramesPerSecond ?? media.framesPerSecond),
            "audioChannels": .value(diagnostics.audio.sourceChannels),
            "outputChannels": .value(diagnostics.audio.outputChannels),
            "audioOutput": .value(diagnostics.audio.output),
            "outputFormat": .value(diagnostics.audio.outputFormat),
            "decoderDroppedFrames": .value(diagnostics.decoderDroppedFrames),
            "outputDroppedFrames": .value(diagnostics.outputDroppedFrames),
            "mistimedFrames": .value(diagnostics.mistimedFrames),
            "delayedFrames": .value(diagnostics.delayedFrames),
            "audioVideoDriftSeconds": .value(diagnostics.audioVideoDriftSeconds),
            "estimatedFilterFramesPerSecond": .value(diagnostics.estimatedFilterFramesPerSecond),
            "nominalDisplayFramesPerSecond": .value(diagnostics.nominalDisplayFramesPerSecond),
            "estimatedDisplayFramesPerSecond": .value(diagnostics.estimatedDisplayFramesPerSecond),
            "pixelFormat": .value(diagnostics.decoder.decodedPixelFormat),
            "interop": .value(diagnostics.decoder.interop),
            "decoder": .value(diagnostics.decoder.selectedDecoder),
            "deinterlaceActive": .value(diagnostics.deinterlace.isActive),
            "interlaced": .value(diagnostics.deinterlace.outputFrameIsInterlaced),
            "filters": .list(diagnostics.deinterlace.effectiveFilter.map { [.string($0)] } ?? []),
            "effectiveOptions": .strings(diagnostics.renderingQuality.effectiveOptions),
            "renderPasses": .list((diagnostics.freshRenderPasses ?? []).map { .record([
                "name": .string($0.name),
                "averageNanoseconds": .value($0.averageNanoseconds)
            ]) }),
            "startLatencySeconds": .value(diagnostics.startLatencySeconds),
            "seekLatencySeconds": .value(diagnostics.seekLatencySeconds),
            "fallbackReasons": .list(diagnostics.fallbackReasons.map(Self.string)),
            "renderingPreset": .string(diagnostics.renderingQuality.resolvedPreset == .highQuality ? "HIGH_QUALITY" : diagnostics
                .renderingQuality
                .resolvedPreset
                .rawValue
                .uppercased()),
            "unsupportedFeatures": .list(diagnostics.renderingQuality.unsupportedFeatures.map(Self.string)),
        ])
        result["videoFeatureCapabilities"] = .capabilities(
            value.videoFeatureCapabilities,
            hasVideo: media.tracks.contains { $0.type == .video }
        )
        result["videoFeatureRequestResult"] = value.videoFeatureRequestResult.map(Self.featureResult) ?? .null
        return .record(result)
    }

    static func wireName(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).uppercased()
    }

    static func capabilities(_ value: MPVVideoFeatureCapabilities, hasVideo: Bool) -> Self {
        .record([
            "backend": .value(value.backend == .nativeSurface ? "NATIVE_SURFACE" : value.backend == .gpu ? "GPU" : nil),
            "hasVideo": .flag(hasVideo),
            "features": .record(Dictionary(uniqueKeysWithValues: MPVVideoFeature.allCases.map { feature in
                let capability = value[feature]
                return (wireName(feature.rawValue), .record([
                    "availability": .string(wireName(capability.availability.rawValue)),
                    "restriction": .value(capability.restriction
                        .map { wireName($0.rawValue) })
                ]))
            }))
        ])
    }

    static func featureResult(_ value: MPVVideoFeatureRequestResult) -> Self {
        .record([
            "outcome": .string(wireName(value.outcome.rawValue)),
            "requestedFeatures": .list(value.requestedFeatures
                .sorted { $0.rawValue < $1.rawValue }
                .map { .string(wireName($0.rawValue)) }),
            "unavailableFeatures": .list(value.unavailableFeatures
                .sorted { $0.rawValue < $1.rawValue }
                .map { .string(wireName($0.rawValue)) }),
            "reason": .value(value.reason)
        ])
    }
}
