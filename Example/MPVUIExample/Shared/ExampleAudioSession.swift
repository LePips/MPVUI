import Foundation

#if os(iOS) || os(tvOS)
import AVFAudio
#endif

/// Manages the example app's playback audio session.
@MainActor
public enum ExampleAudioSession {
    /// Activates movie playback audio on iOS and tvOS, returning any error message.
    @discardableResult
    public static func activate() -> String? {
        #if os(iOS) || os(tvOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            return nil
        } catch {
            return error.localizedDescription
        }
        #else
        return nil
        #endif
    }

    /// Releases the iOS or tvOS audio session, returning any error message.
    @discardableResult
    public static func deactivate() -> String? {
        #if os(iOS) || os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            return nil
        } catch {
            return error.localizedDescription
        }
        #else
        return nil
        #endif
    }
}
