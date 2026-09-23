/// Audio decoding, spatialization, and session settings for ``MPVPlayer``.
///
/// Set ``MPVPlayerConfiguration/audio`` before creating the player.
/// Changes require a new player.
public struct MPVAudioConfiguration: Equatable, Sendable {

    // MARK: - Types

    /// Who configures the shared iOS/tvOS audio session. Ignored on macOS.
    public enum AudioSession: String, CaseIterable, Sendable {
        /// Activate the playback category, movie-playback mode, and multichannel
        /// support when audio opens. The host handles interruptions and deactivation.
        case automatic
        /// The host configures, activates, and deactivates `AVAudioSession`.
        /// Use `.playback`, `.moviePlayback`, and `setSupportsMultichannelContent(true)`.
        case hostManaged
    }

    /// How AC-3 and E-AC-3 audio are decoded.
    public enum DolbyDecoding: String, CaseIterable, Sendable {
        /// Send AC-3/E-AC-3 to Apple, preserving any embedded Atmos data.
        /// Unsupported routes, audio processing, or playback failures fall back to PCM.
        /// Apple determines whether Atmos is rendered on the active route.
        case automatic
        /// Decode to PCM in mpv. Surround channels remain spatializable, but
        /// Atmos object metadata is not delivered through this path.
        case software
    }

    /// Content eligible for Apple's spatializer. System settings still control
    /// Off, Fixed, Head Tracked, and Personalized Spatial Audio.
    public enum Spatialization: String, CaseIterable, Sendable {
        /// Allow mono, stereo, and surround content.
        case automatic
        /// Allow surround content only.
        case multichannel
        /// Disable Apple's spatializer for this player (for example, binaural media).
        case disabled

        var mpvValue: String {
            switch self {
            case .automatic: "all"
            case .multichannel: "multichannel"
            case .disabled: "no"
            }
        }
    }

    // MARK: - Properties

    /// Audio-session ownership on iOS/tvOS. Defaults to `.automatic`.
    public let audioSession: AudioSession

    /// How AC-3 and E-AC-3 are decoded. Defaults to `.automatic`.
    public let dolbyDecoding: DolbyDecoding

    /// Source layouts eligible for Apple's spatializer. Defaults to `.automatic`.
    public let spatialization: Spatialization

    /// Creates audio settings with automatic decoding, spatialization, and session setup.
    public init(
        audioSession: AudioSession = .automatic,
        dolbyDecoding: DolbyDecoding = .automatic,
        spatialization: Spatialization = .automatic
    ) {
        self.audioSession = audioSession
        self.dolbyDecoding = dolbyDecoding
        self.spatialization = spatialization
    }

    var mpvOptions: [String: String] {
        [
            "ao-avfoundation-spatial-audio": spatialization.mpvValue,
            "ao-avfoundation-manage-audio-session": audioSession == .automatic ? "yes" : "no",
            "audio-spdif": dolbyDecoding == .automatic ? "ac3,eac3" : "",
        ]
    }
}
