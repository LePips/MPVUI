import Foundation

package extension MPVSession {

    func applyBufferingPolicy(initial: Bool) {
        isInitialBufferingPending = initial
        let duration = initial ? configuration.initialBufferDuration : configuration.rebufferDuration
        let options = [
            "cache-pause-wait": Self.format(duration),
            // mpv uses this switch for seeking as well as initial playback.
            "cache-pause-initial": duration > .zero ? "yes" : "no",
        ]

        for (name, configuredValue) in options {
            // Explicit native settings remain authoritative across both phases.
            let value = playbackPolicyOverride(for: name) ?? configuredValue
            let status = setPropertyImmediately("file-local-options/\(name)", to: value)

            if status < 0 {
                publishCommandError(status, context: "Set \(initial ? "initial" : "recovery") buffering")
            }
        }
    }

    func completeInitialBufferingIfReady() {
        // mpv emits playback-restart before an initial cache pause finishes.
        // Keep the startup target until that pause clears, even when the user
        // has separately paused playback.
        guard isInitialBufferingPending, hasPlaybackStarted,
              getFlag("paused-for-cache") == false else { return }

        applyBufferingPolicy(initial: false)
    }
}
