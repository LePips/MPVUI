@testable import MPVUI
import Testing

@Suite(.tags(.unit, .hdr))
struct MPVHDRSurfacePolicyTests {
    @Test(arguments: [(Double(2), "406"), (0, "203"), (.nan, "203"), (.infinity, "203"), (.greatestFiniteMagnitude, "203"), (100, "10000")])
    func `legacy color targets bound peak luminance and retain explicit SDR defaults`(headroom: Double, peak: String) {
        let hdr = Dictionary(uniqueKeysWithValues: MPVEngine.colorTargetOptions(usesExtendedDynamicRange: true, outputHeadroom: headroom))
        #expect(hdr == ["target-prim": "display-p3", "target-trc": "linear", "target-peak": peak])
        let sdr = Dictionary(uniqueKeysWithValues: MPVEngine.colorTargetOptions(usesExtendedDynamicRange: false, outputHeadroom: headroom))
        #expect(sdr == ["target-prim": "bt.709", "target-trc": "srgb", "target-peak": "auto"])
    }

    @Test
    func `optional subtitle luminance fallback remains visible without a stronger policy failure`() {
        #expect(MPVEngine
            .resolvedPresentationFallback(backend: .unsupportedSubtitleLuminance, policy: nil, liveFailure: nil) ==
            .unsupportedSubtitleLuminance)
    }

    @Test(arguments: [MPVPlayerConfiguration.HDRPolicy.automatic, .always, .constrained, .disabled], [true, false])
    func `native layer reports display limitations only for requested HDR`(_ policy: MPVPlayerConfiguration.HDRPolicy, sourceHDR: Bool) {
        let result = resolve(policy, native: true, displayHDR: false, sourceHDR: sourceHDR)
        let expected: MPVPresentationStatus.FallbackReason? = switch policy {
        case .disabled: nil
        case .automatic: sourceHDR ? .displayDoesNotSupportHDR : nil
        case .always, .constrained: .displayDoesNotSupportHDR
        }
        #expect(result.fallbackReason == expected)
        #expect(!result.usesExtendedDynamicRange)
    }

    @Test
    func `native automatic remains OS managed rather than reporting SDR`() {
        let result = resolve(.automatic, native: true, layerPolicy: false)
        #expect(result.dynamicRange == .automatic)
        #expect(result.fallbackReason == nil)
    }

    @Test(arguments: [MPVPlayerConfiguration.HDRPolicy.disabled, .always, .constrained])
    func `older native layers report unsupported explicit requests`(_ policy: MPVPlayerConfiguration.HDRPolicy) {
        let result = resolve(policy, native: true, layerPolicy: false)
        #expect(result.dynamicRange == .automatic)
        #expect(result.fallbackReason == .unsupportedPolicy)
    }

    @Test
    func `native layer requests distinguish SDR HDR and constrained HDR`() {
        #expect(resolve(.disabled, native: true).dynamicRange == .sdr)
        #expect(resolve(.always, native: true).dynamicRange == .hdr)
        #expect(resolve(.constrained, native: true).dynamicRange == .constrainedHDR)
    }

    @Test
    func `tvOS Metal only configures HDR when platform supports it`() {
        let unavailable = resolve(.always, metalHDR: false)
        #expect(!unavailable.usesExtendedDynamicRange)
        #expect(unavailable.dynamicRange == .sdr)
        #expect(unavailable.fallbackReason == .unsupportedPolicy)
        let available = resolve(.always)
        #expect(available.usesExtendedDynamicRange)
        #expect(available.dynamicRange == .hdr)
    }

    @Test
    func `automatic follows source and SDR always requests tone mapping`() {
        #expect(!resolve(.automatic, sourceHDR: false).usesExtendedDynamicRange)
        #expect(resolve(.automatic, sourceHDR: true).usesExtendedDynamicRange)
        #expect(!resolve(.disabled, sourceHDR: true).usesExtendedDynamicRange)
        #expect(resolve(.always, displayHDR: false).fallbackReason == .displayDoesNotSupportHDR)
    }

    @Test
    func `constrained HDR cannot silently claim enforcement on old systems`() {
        let result = resolve(.constrained, layerPolicy: false)
        #expect(result.dynamicRange == .hdr)
        #expect(result.fallbackReason == .unsupportedPolicy)
    }

    private func resolve(
        _ policy: MPVPlayerConfiguration.HDRPolicy,
        native: Bool = false,
        layerPolicy: Bool = true,
        metalHDR: Bool = true,
        displayHDR: Bool = true,
        sourceHDR: Bool = true
    ) -> MPVHDRSurfacePolicy {
        .init(
            displaySupportsHDR: displayHDR,
            native: native,
            policy: policy,
            sourceIsHDR: sourceHDR,
            supportsLayerPolicy: layerPolicy,
            supportsMetalHDR: metalHDR
        )
    }
}
