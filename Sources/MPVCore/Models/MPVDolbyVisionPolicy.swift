/// Dolby Vision behavior requested when creating a native decoder.
public enum MPVDolbyVisionPolicy: String, CaseIterable, Equatable, Sendable {

    /// Disables native Profile 7 conversion. Unsupported streams fail native
    /// playback. This policy does not guarantee enhancement-layer reproduction.
    case strict

    /// Allows lossy Profile 7 to Profile 8.1 compatibility conversion.
    /// Conversion discards the enhancement layer and does not reproduce full FEL video.
    case profile7Compatibility

    /// The decoder uses this policy for its lifetime. Create a player
    /// with the new policy and reload the item to change it.
    public var changesRequireReload: Bool {
        true
    }

    package var nativeMPVValue: String {
        self == .strict ? "no" : "p8.1"
    }
}
