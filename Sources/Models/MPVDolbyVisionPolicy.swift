/// Dolby Vision behavior requested when creating a native decoder.
public enum MPVDolbyVisionPolicy: String, CaseIterable, Equatable, Sendable {
    /// Do not opt into native Profile 7 conversion. Unsupported native streams
    /// fail native playback; this does not establish enhancement-layer reproduction.
    case strict

    /// Explicitly permit lossy Profile 7 to Profile 8.1 compatibility conversion.
    /// The enhancement layer is discarded. This does not reproduce full FEL video.
    case profile7Compatibility

    /// This option is latched when the decoder is created. Construct a player
    /// with the new policy and reload the item to change it.
    public var changesRequireReload: Bool {
        true
    }

    var nativeMPVValue: String {
        self == .strict ? "no" : "p8.1"
    }
}
