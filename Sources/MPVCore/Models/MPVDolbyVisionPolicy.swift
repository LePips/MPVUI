/// Dolby Vision behavior requested when creating a native decoder.
/// Native sample-buffer output accepts validated HEVC Profiles 5, 8.1, and 8.4
/// on supported hardware. Profile 7 requires explicit compatibility conversion.
public enum MPVDolbyVisionPolicy: String, CaseIterable, Equatable, Sendable {

    /// Disables native Profile 7 conversion. Unsupported streams fail native
    /// playback. This policy does not guarantee enhancement-layer reproduction.
    case strict

    /// Allows lossy Profile 7 to Profile 8.1 compatibility conversion.
    /// Conversion discards the enhancement layer and does not reproduce full FEL video.
    case profile7Compatibility

    /// Whether changing this policy requires recreating the decoder and reloading media.
    /// Always `true`. Create a player with the new policy to apply it.
    public var changesRequireReload: Bool {
        true
    }

    package var nativeMPVValue: String {
        self == .strict ? "no" : "p8.1"
    }
}
