/// Audio decoding, spatialization, and session settings for ``MPVPlayer``.
///
/// Set ``MPVPlayerConfiguration/audio`` before creating the player.
/// Changes require a new player.
public struct MPVAudioConfiguration: Equatable, Sendable {

    // MARK: - Types

    /// Ownership of the shared audio session on iOS and tvOS. Has no effect on macOS.
    public enum AudioSession: String, CaseIterable, Sendable {

        /// Activates the playback category, movie-playback mode, and multichannel
        /// support when audio opens. The host handles interruptions and deactivation.
        case automatic
        /// The host configures, activates, and deactivates `AVAudioSession`.
        /// Use `.playback`, `.moviePlayback`, and `setSupportsMultichannelContent(true)`.
        case hostManaged
    }

    /// The decoding method for AC-3 and E-AC-3 audio.
    public enum DolbyDecoding: String, CaseIterable, Sendable {

        /// Sends AC-3 and E-AC-3 to Apple, preserving any embedded Atmos data.
        /// Unsupported routes, audio processing, or playback failures fall back to PCM.
        /// Apple determines whether the active route renders Atmos.
        case automatic
        /// Decodes to PCM in mpv. Surround channels support spatialization, but
        /// this path does not deliver Atmos object metadata.
        case software
    }

    /// Content eligible for Apple's spatializer. System settings still control
    /// Off, Fixed, Head Tracked, and Personalized Spatial Audio.
    public enum Spatialization: String, CaseIterable, Sendable {

        /// Allows mono, stereo, and surround content, including audio-only media.
        case automatic
        /// Allows surround content only.
        case multichannel
        /// Disables Apple's spatializer for this player, for example, for binaural media.
        case disabled

        package var mpvValue: String {
            switch self {
            case .automatic: "all"
            case .multichannel: "multichannel"
            case .disabled: "no"
            }
        }
    }

    /// Audio-session ownership on iOS and tvOS. Defaults to `.automatic`.
    public let audioSession: AudioSession

    /// The decoding method for AC-3 and E-AC-3. Defaults to `.automatic`.
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
}
