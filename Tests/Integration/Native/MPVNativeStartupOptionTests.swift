import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .nativePatch))
struct MPVNativeStartupOptionTests {
    @MainActor @Test(.serialized, arguments: ["aac", "webp", "webp_anim", "prores_raw"])
    func `bundled mpv exposes required media decoder`(codec: String) throws {
        let session = try NativePlaybackSession()
        defer { session.close() }
        let decoders = try #require(session.property("decoder-list")?.arrayValue)
        let names = Set(decoders.compactMap { $0.mapValue?["codec"]?.stringValue })
        #expect(names.contains(codec), "Missing decoder: \(codec)")
    }

    static let options = [
        ("vo", "gpu-next"),
        ("gpu-api", "vulkan"),
        ("gpu-context", "moltenvk"),
        ("external-surface-size", "640x360"),
        ("target-colorspace-hint", "yes"),
        ("input-default-bindings", "no"),
        ("subs-match-os-language", "yes"),
        ("subs-fallback", "yes"),
        ("sub-text-intercept", "yes"),
        ("ao", "avfoundation,"),
        ("ao-avfoundation-accept-compressed", "yes"),
        ("ao-avfoundation-compressed-lead", "1"),
        ("ao-avfoundation-compressed-lead", "30"),
        ("avfoundation-native-dovi-profile7", "no"),
        ("avfoundation-native-dovi-profile7", "p8.1"),
        ("hwdec", "auto-safe"),
        ("hwdec-software-fallback", "auto"),
        ("hwdec-software-fallback", "yes"),
        ("hwdec-software-fallback", "no"),
        ("hwdec-software-fallback", "3"),
        ("cache", "auto"),
        ("cache-secs", "10"),
        ("cache-pause", "yes"),
        ("cache-pause-initial", "yes"),
        ("cache-pause-wait", "1"),
        ("loop-file", "no"),
        ("volume", "100"),
        ("speed", "1"),
        ("target-prim", "display-p3"),
        ("target-trc", "linear"),
        ("target-peak", "812"),
        ("target-peak", "203"),
        ("target-trc", "srgb"),
        ("target-peak", "auto"),
    ]

    @Test(arguments: options)
    func `bundled mpv accepts required startup option`(name: String, value: String) throws {
        let handle = try #require(mpv_create())
        defer { mpv_destroy(handle) }
        #expect(mpv_set_option_string(handle, name, value) >= 0, "Bundled mpv rejected \(name)=\(value)")
    }
}
