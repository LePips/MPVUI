import CoreMedia
import CoreVideo
import Foundation

#if os(tvOS)
import AVFoundation
import AVKit
import UIKit
#endif

/// Content characteristics used as a display-mode hint, never as a decoder format.
/// Unknown color properties remain absent. An enforced SDR conversion replaces
/// the source HDR description so it cannot request an HDR HDMI mode accidentally.
struct MPVDisplayMatchingContent: Equatable {
    let width: Int32
    let height: Int32
    let refreshRate: Float
    let codec: CMVideoCodecType
    let signal: MPVVideoSignal
    let convertsHDRToSDR: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.refreshRate == rhs.refreshRate, lhs.codec == rhs.codec,
              lhs.convertsHDRToSDR == rhs.convertsHDRToSDR
        else { return false }
        if lhs.convertsHDRToSDR {
            return true
        }
        // Dynamic scene metadata and signal-peak changes do not select a new
        // HDMI mode. Compare only fields represented by this display hint.
        return lhs.signal.primaries == rhs.signal.primaries
            && lhs.signal.transferFunction == rhs.signal.transferFunction
            && lhs.signal.matrix == rhs.signal.matrix
            && lhs.signal.range == rhs.signal.range
            && lhs.signal.bitDepth == rhs.signal.bitDepth
            && lhs.signal.maxContentLightLevel == rhs.signal.maxContentLightLevel
            && lhs.signal.maxFrameAverageLightLevel == rhs.signal.maxFrameAverageLightLevel
    }

    init?(media: MPVMediaInformation, outputUsesHDR: Bool) {
        let selectedCodec = media.tracks.first { $0.type == .video && $0.isSelected }?.codec
        guard let dimensions = media.dimensions,
              let width = Int32(exactly: dimensions.width), width > 0,
              let height = Int32(exactly: dimensions.height), height > 0,
              let refreshRate = Self.refreshRate(for: media.framesPerSecond),
              let codec = Self.codecType(for: selectedCodec ?? media.videoCodec)
        else { return nil }

        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.codec = codec
        let decoded = media.hdr.decoded
        signal = decoded == .unknown ? media.hdr.source : decoded
        convertsHDRToSDR = signal.transferFunction.isHDR && !outputUsesHDR
    }

    /// Preserve the NTSC rational families, including when mpv reports their
    /// common three-decimal spelling. In particular, never round 23.976 to 24.
    static func refreshRate(for framesPerSecond: Double?) -> Float? {
        guard let value = framesPerSecond, value.isFinite,
              value > 0, value <= 240
        else { return nil }
        let standardRates = [
            24000.0 / 1001, 24, 25, 30000.0 / 1001, 30,
            48000.0 / 1001, 48, 50, 60000.0 / 1001, 60,
            100, 120_000.0 / 1001, 120,
        ]
        let rate = standardRates.first { abs($0 - value) < 0.001 } ?? value
        return Float(rate)
    }

    func makeFormatDescription() -> CMVideoFormatDescription? {
        var extensions: [String: Any] = [:]
        if convertsHDRToSDR {
            // The renderer's SDR contract is BT.709/sRGB. Do not copy mastering,
            // content-light or Dolby Vision metadata across this conversion.
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] =
                kCMFormatDescriptionTransferFunction_sRGB
        } else {
            if let primaries = Self.colorPrimaries(signal.primaries) {
                extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
            }
            if let transfer = Self.transferFunction(signal.transferFunction) {
                extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
            }
            if let matrix = Self.colorMatrix(signal.matrix) {
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix
            }
            switch signal.range?.lowercased() {
            case "full", "pc":
                extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = true
            case "limited", "tv":
                extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = false
            default:
                break
            }
            if let depth = signal.bitDepth {
                extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] = depth
            }
            if signal.transferFunction.isHDR,
               let maxCLL = signal.maxContentLightLevel,
               let maxFALL = signal.maxFrameAverageLightLevel,
               maxCLL.isFinite, maxFALL.isFinite,
               maxCLL >= 0, maxFALL >= 0,
               maxCLL <= Double(UInt16.max), maxFALL <= Double(UInt16.max)
            {
                let cll = UInt16(maxCLL.rounded())
                let fall = UInt16(maxFALL.rounded())
                extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = Data([
                    UInt8(cll >> 8), UInt8(cll & 0xFF),
                    UInt8(fall >> 8), UInt8(fall & 0xFF),
                ])
            }
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func codecType(for value: String?) -> CMVideoCodecType? {
        switch value?.lowercased() {
        case "h264", "avc1": kCMVideoCodecType_H264
        case "hevc", "h265", "hev1", "hvc1": kCMVideoCodecType_HEVC
        case "av1", "av01": kCMVideoCodecType_AV1
        case "vp9", "vp09": kCMVideoCodecType_VP9
        case "mpeg4": kCMVideoCodecType_MPEG4Video
        case "mpeg2video": kCMVideoCodecType_MPEG2Video
        default: nil
        }
    }

    private static func colorPrimaries(_ value: String?) -> CFString? {
        switch value?.lowercased() {
        case "bt.709", "bt709": kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case "bt.601-525", "smpte170m", "smpte-c": kCMFormatDescriptionColorPrimaries_SMPTE_C
        case "bt.601-625", "bt470bg": kCMFormatDescriptionColorPrimaries_EBU_3213
        case "bt.2020", "bt2020": kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case "display-p3", "p3-d65": kCMFormatDescriptionColorPrimaries_P3_D65
        case "dci-p3", "p3-dci": kCMFormatDescriptionColorPrimaries_DCI_P3
        default: nil
        }
    }

    private static func colorMatrix(_ value: String?) -> CFString? {
        switch value?.lowercased() {
        case "bt.709", "bt709": kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case "bt.601", "bt601", "smpte170m", "bt470bg": kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case "bt.2020-ncl", "bt.2020-cl", "bt2020nc", "bt2020c": kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case "smpte-240m", "smpte240m": kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        default: nil
        }
    }

    private static func transferFunction(_ value: MPVTransferFunction) -> CFString? {
        switch value {
        case .bt709, .bt1886: kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .sRGB: kCMFormatDescriptionTransferFunction_sRGB
        case .linear: kCMFormatDescriptionTransferFunction_Linear
        case .pq: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: nil
        }
    }
}

/// Testable policy independent of HDMI hardware or notification timing.
struct MPVDisplayMatchingState {
    enum Action: Equatable {
        case keep
        case clear
        case apply(MPVDisplayMatchingContent)
    }

    private(set) var content: MPVDisplayMatchingContent?
    private(set) var mediaGeneration: UInt64?

    mutating func ownershipDidChange() {
        // Generations are player-local. A different player may have the same
        // numeric generation, including when its next item has no video.
        mediaGeneration = nil
    }

    mutating func update(
        candidate: MPVDisplayMatchingContent?,
        mediaGeneration: UInt64,
        playbackState: MPVPlaybackState,
        matchingEnabled: Bool,
        isActive: Bool,
        modeSwitchInProgress: Bool
    ) -> Action {
        guard isActive, matchingEnabled,
              playbackState != .idle, !playbackState.isTerminal
        else {
            return clear()
        }

        // The display can be blank for seconds. Do not restart a mode switch,
        // or momentarily restore the UI mode for seeks or next-item loading.
        guard !modeSwitchInProgress,
              playbackState != .loading,
              playbackState != .seeking,
              playbackState != .buffering
        else { return .keep }

        guard let candidate else {
            // Retain a known format during same-item metadata refreshes; an
            // audio-only or unknown-format next item must release the old mode.
            return self.mediaGeneration == mediaGeneration ? .keep : clear()
        }
        self.mediaGeneration = mediaGeneration
        guard content != candidate else { return .keep }
        content = candidate
        return .apply(candidate)
    }

    private mutating func clear() -> Action {
        mediaGeneration = nil
        guard content != nil else { return .keep }
        content = nil
        return .clear
    }
}

#if os(tvOS)
/// One active surface owns each window's display criteria. An old surface can
/// neither clear nor reclaim a successor's criteria merely by being detached.
@MainActor
final class MPVDisplayMatchingCoordinator {
    private static var owners: [ObjectIdentifier: WeakBox<MPVDisplayMatchingCoordinator>] = [:]

    private var manager: AVDisplayManager?
    private var observations: [NSObjectProtocol] = []
    private var matchingState = MPVDisplayMatchingState()
    private var latestInput: Input?
    private(set) var isDisplayModeSwitchInProgress = false
    var displayModeSwitchDidChange: ((Bool) -> Void)?

    private struct Input {
        let media: MPVMediaInformation
        let mediaGeneration: UInt64
        let state: MPVPlaybackState
        let outputUsesHDR: Bool
    }

    func update(
        window: UIWindow?,
        media: MPVMediaInformation,
        mediaGeneration: UInt64,
        state: MPVPlaybackState,
        isActive: Bool,
        outputUsesHDR: Bool
    ) {
        guard isActive, let window else {
            detach()
            return
        }
        attach(to: window.avDisplayManager)
        latestInput = Input(
            media: media, mediaGeneration: mediaGeneration,
            state: state, outputUsesHDR: outputUsesHDR
        )
        refresh()
    }

    func detach() {
        if let manager, Self.owners[ObjectIdentifier(manager)]?.value === self {
            Self.owners.removeValue(forKey: ObjectIdentifier(manager))
            manager.preferredDisplayCriteria = nil
        }
        releaseObservations()
        manager = nil
        matchingState = MPVDisplayMatchingState()
        latestInput = nil
        setModeSwitchInProgress(false)
    }

    isolated deinit {
        detach()
    }

    private func attach(to manager: AVDisplayManager) {
        guard self.manager !== manager
            || Self.owners[ObjectIdentifier(manager)]?.value !== self
        else { return }
        detach()
        let key = ObjectIdentifier(manager)
        // Relinquish the retiring owner's notifications without clearing the
        // active criteria. This prevents an unnecessary intermediate blackout.
        if let previous = Self.owners[key]?.value {
            previous.releaseObservations()
            previous.manager = nil
            previous.latestInput = nil
            matchingState = previous.matchingState
            matchingState.ownershipDidChange()
            previous.matchingState = MPVDisplayMatchingState()
            previous.setModeSwitchInProgress(false)
        }
        self.manager = manager
        Self.owners[key] = WeakBox(self)
        for name in [
            NSNotification.Name.AVDisplayManagerModeSwitchStart,
            NSNotification.Name.AVDisplayManagerModeSwitchEnd,
            NSNotification.Name.AVDisplayManagerModeSwitchSettingsChanged,
        ] {
            observations.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: manager, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
    }

    private func refresh() {
        guard let manager, let input = latestInput,
              Self.owners[ObjectIdentifier(manager)]?.value === self
        else { return }
        setModeSwitchInProgress(manager.isDisplayModeSwitchInProgress)
        let candidate = MPVDisplayMatchingContent(
            media: input.media, outputUsesHDR: input.outputUsesHDR
        )
        let action = matchingState.update(
            candidate: candidate,
            mediaGeneration: input.mediaGeneration,
            playbackState: input.state,
            matchingEnabled: manager.isDisplayCriteriaMatchingEnabled,
            isActive: true,
            modeSwitchInProgress: isDisplayModeSwitchInProgress
        )
        switch action {
        case .keep:
            break
        case .clear:
            manager.preferredDisplayCriteria = nil
        case let .apply(content):
            guard let formatDescription = content.makeFormatDescription() else {
                matchingState = MPVDisplayMatchingState()
                manager.preferredDisplayCriteria = nil
                return
            }
            manager.preferredDisplayCriteria = AVDisplayCriteria(
                refreshRate: content.refreshRate,
                formatDescription: formatDescription
            )
        }
    }

    private func setModeSwitchInProgress(_ value: Bool) {
        guard isDisplayModeSwitchInProgress != value else { return }
        isDisplayModeSwitchInProgress = value
        displayModeSwitchDidChange?(value)
    }

    private func releaseObservations() {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
    }
}
#endif
