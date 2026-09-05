import Foundation

#if os(iOS) || os(tvOS)
import AVFAudio
#endif

@MainActor
public enum ExampleAudioSession {
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
