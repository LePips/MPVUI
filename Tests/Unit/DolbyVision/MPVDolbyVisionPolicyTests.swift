import Foundation
@testable import MPVUI
import Testing

/// Policy and evidence tests. These do not validate physical Dolby Vision output,
/// parse real MEL/FEL bitstreams or certify a television's reconstruction.
@Suite(.tags(.unit, .dolbyVision))
struct MPVDolbyVisionPolicyTests {
    @Test
    func `duplicate diagnostic fields use the last valid value without inventing source metadata`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        let consumed = resolver.consume(log: log(
            "MPVUI_NATIVE_DOLBY_VISION_VALIDATED: ignored profile7-to81=no session-profile=5 session-profile=8 session-compatibility=4"
        ))
        #expect(consumed)
        let status = resolver.status(source: .unknown, backend: .sampleBuffer)
        #expect(status.effectiveProfile == 8)
        #expect(status.effectiveBaseLayerCompatibilityID == 4)
        #expect(status.sourceProfile == nil)
    }

    @Test
    func `strict is the default and compatibility is explicit and requires reload`() {
        let config = MPVPlayerConfiguration()
        #expect(config.dolbyVisionPolicy == .strict)
        #expect(config.nativeVideoFeaturePolicy == .preserveDolbyVision)
        #expect(MPVDolbyVisionPolicy.strict.nativeMPVValue == "no")
        #expect(MPVDolbyVisionPolicy.profile7Compatibility.nativeMPVValue == "p8.1")
        #expect(MPVDolbyVisionPolicy.profile7Compatibility.changesRequireReload)
    }

    @Test(arguments: [(5, 0), (8, 1), (8, 4)])
    func `P5 P81 and P84 require native frame evidence`(profile: Int, compatibility: Int) {
        var resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        let source = MPVVideoSignal(dolbyVisionProfile: profile, dolbyVisionBaseLayerCompatibilityID: compatibility)
        #expect(resolver.status(source: source, backend: .sampleBuffer).effectiveProfile == nil)
        resolver.consume(log: validated())
        let status = resolver.status(source: source, backend: .sampleBuffer)
        #expect(status.sourceProfile == profile)
        #expect(status.effectiveProfile == profile)
        #expect(status.effectiveBaseLayerCompatibilityID == compatibility)
        #expect(status.nativeValidation == .validated)
        #expect(status.enhancementLayer == .unknown)
    }

    @Test
    func `P7 policy does not claim conversion until renderer validates the frame`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .profile7Compatibility)
        let source = MPVVideoSignal(dolbyVisionProfile: 7, dolbyVisionBaseLayerCompatibilityID: 6)
        let pending = resolver.status(source: source, backend: .sampleBuffer)
        #expect(pending.conversion == .pending)
        #expect(pending.effectiveProfile == nil)
        #expect(pending.enhancementLayer == .unknown)
        resolver.consume(log: validated(converted: true))
        let status = resolver.status(source: source, backend: .sampleBuffer)
        #expect(status.sourceProfile == 7)
        #expect(status.effectiveProfile == 8)
        #expect(status.effectiveBaseLayerCompatibilityID == 1)
        #expect(status.conversion == .converted)
        #expect(status.enhancementLayer == .discarded)
        #expect(status.reason?.contains("full FEL reproduction is not provided") == true)
        #expect(status.policyChangesRequireReload)
    }

    @Test
    func `missing profile and subtype stay unknown even with native validation`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        resolver.consume(log: validated())
        let missing = resolver.status(source: .unknown, backend: .sampleBuffer)
        #expect(missing.nativeValidation == .validated)
        #expect(missing.sourceProfile == nil)
        #expect(missing.effectiveProfile == nil)
        let profile8 = resolver.status(source: MPVVideoSignal(dolbyVisionProfile: 8), backend: .sampleBuffer)
        #expect(profile8.effectiveBaseLayerCompatibilityID == nil)
    }

    @Test
    func `native effective session metadata does not invent source metadata`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        resolver.consume(log: log("MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=no session-profile=8 session-compatibility=4"))
        let status = resolver.status(source: .unknown, backend: .sampleBuffer)
        #expect(status.sourceProfile == nil)
        #expect(status.sourceBaseLayerCompatibilityID == nil)
        #expect(status.effectiveProfile == 8)
        #expect(status.effectiveBaseLayerCompatibilityID == 4)
        #expect(status.nativeValidation == .validated)
    }

    @Test
    func `unrelated channels and quoted sentinel text cannot validate native Dolby Vision`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        for message in [
            MPVLogMessage(prefix: "ffmpeg/demuxer", level: .info, message: "MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=no"),
            MPVLogMessage(prefix: "ffmpeg/video", level: .info, message: "hevc: MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=no"),
            log("Error quoting MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=no"),
        ] {
            let consumed = resolver.consume(log: message)
            #expect(!consumed)
        }
        #expect(resolver.status(source: .unknown, backend: .sampleBuffer).nativeValidation == .unknown)
        let rejected = resolver.consume(log: MPVLogMessage(
            prefix: "ffmpeg/video", level: .error,
            message: "hevc: MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED: unsupported declared Profile 7"
        ))
        #expect(rejected)
        #expect(resolver.status(source: .unknown, backend: .sampleBuffer).nativeValidation == .rejected)
    }

    @Test
    func `P8 subtype parsing uses explicit compatibility tags and never transfer inference`() {
        let tagged = MPVVideoSignalParser.parse(nil, track: .map([
            "dolby-vision-profile": .integer(8),
            "dolby-vision-bl-signal-compatibility-id": .integer(4),
        ]))
        #expect(tagged.dolbyVisionBaseLayerCompatibilityID == 4)
        let unspecified = MPVVideoSignalParser.parse(.map([
            "gamma": .string("hlg"), "dolby-vision-profile": .integer(8),
        ]))
        #expect(unspecified.dolbyVisionBaseLayerCompatibilityID == nil)
        let malformed = MPVVideoSignalParser.parse(.map([
            "dolby-vision-bl-signal-compatibility-id": .integer(1000),
        ]))
        #expect(malformed.dolbyVisionBaseLayerCompatibilityID == nil)
    }

    @Test
    func `strict policy rejects unexpected compatibility success and malformed messages`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        let consumed = resolver.consume(log: log("MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=maybe"))
        #expect(!consumed)
        #expect(resolver.status(source: .unknown, backend: .sampleBuffer).nativeValidation == .unknown)
        resolver.consume(log: validated(converted: true))
        let status = resolver.status(source: MPVVideoSignal(dolbyVisionProfile: 7), backend: .sampleBuffer)
        #expect(status.nativeValidation == .rejected)
        #expect(status.effectiveProfile == nil)
    }

    @Test
    func `a later malformed RPU revokes accepted conversion and the next item resets evidence`() {
        var resolver = MPVDolbyVisionStatusResolver(policy: .profile7Compatibility)
        let source = MPVVideoSignal(dolbyVisionProfile: 7)
        resolver.consume(log: validated(converted: true))
        #expect(resolver.status(source: source, backend: .sampleBuffer).conversion == .converted)
        resolver.consume(log: log("MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED: malformed RPU in subsequent scene"))
        let failed = resolver.status(source: source, backend: .metal)
        #expect(failed.nativeValidation == .rejected)
        #expect(failed.conversion == .unavailable)
        #expect(failed.effectiveProfile == nil)
        #expect(failed.enhancementLayer == .unknown)
        resolver.reset()
        let next = resolver.status(source: .unknown, backend: .sampleBuffer)
        #expect(next.nativeValidation == .unknown)
        #expect(next.reason == nil)
    }

    @Test
    func `profile metadata cannot identify MEL FEL or prove either was reproduced`() {
        // MEL and FEL share Profile 7 container identification. Test that the
        // status cannot make an enhancement-layer claim from those tags.
        let resolver = MPVDolbyVisionStatusResolver(policy: .strict)
        let status = resolver.status(source: MPVVideoSignal(dolbyVisionProfile: 7), backend: .metal)
        #expect(status.enhancementLayer == .unknown)
        #expect(status.effectiveProfile == nil)
    }

    private func validated(converted: Bool = false) -> MPVLogMessage {
        log("MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=\(converted ? "yes" : "no")")
    }

    private func log(_ message: String) -> MPVLogMessage {
        MPVLogMessage(prefix: "vo/avfoundation", level: .info, message: message)
    }
}
