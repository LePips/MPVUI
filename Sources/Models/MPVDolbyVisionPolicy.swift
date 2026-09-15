/// Dolby Vision behavior requested when creating a native decoder.
public enum MPVDolbyVisionPolicy: String, CaseIterable, Equatable, Sendable {
    /// Do not opt into native Profile 7 conversion. Unsupported native streams
    /// use Metal; this does not establish enhancement-layer reproduction.
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

/// Selects the tradeoff when requested video features would modify a native
/// Dolby Vision frame and invalidate its RPU metadata.
public enum MPVNativeVideoFeaturePolicy: String, CaseIterable, Equatable, Sendable {
    /// Keep native Dolby Vision and report unavailable features.
    case preserveDolbyVision
    /// Reload with Metal when a requested feature requires compositing or geometry.
    /// On iOS this also removes native picture-in-picture support.
    case preferFeatures
}
