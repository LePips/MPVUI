@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVAudioPolicyTests {
    @Test
    func `native audio observations distinguish eligibility from route enablement`() {
        let status = MPVAudioStatusParser.parse(
            output: "avfoundation", codec: "eac3", sourceChannels: nil,
            outputChannels: "stereo", outputFormat: "spdif-eac3",
            native: .map([
                "path": .string("avplayer"), "allows-stereo": .bool(true),
                "allows-multichannel": .bool(true), "route-spatial-enabled": .bool(false),
            ])
        )
        #expect(status.nativePath == "avplayer")
        #expect(status.allowsStereoSpatialization == true)
        #expect(status.allowsMultichannelSpatialization == true)
        #expect(status.routeSpatialAudioEnabled == false)
        #expect(status.sourceChannels == nil)
    }

    @Test
    func `unavailable route state remains unknown and fallback discards native state`() {
        for output in ["avfoundation", "coreaudio", "null"] {
            let status = MPVAudioStatusParser.parse(
                output: output, codec: "aac", sourceChannels: "5.1",
                outputChannels: "stereo", outputFormat: "float",
                native: .map(["path": .string("sample-buffer"), "allows-stereo": .bool(true)])
            )
            #expect(status.routeSpatialAudioEnabled == nil)
            #expect(status.allowsMultichannelSpatialization == nil)
            #expect(status.nativePath == (output == "avfoundation" ? "sample-buffer" : nil))
            #expect(status.allowsStereoSpatialization == (output == "avfoundation" ? true : nil))
        }
    }
}
