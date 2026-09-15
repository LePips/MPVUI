extension Duration {

    /// Creates a `Duration` from seconds, protecting against non-finite values.
    init?(mpvSeconds: Double) {
        guard mpvSeconds.isFinite else { return nil }

        let wholeSeconds = mpvSeconds.rounded(.towardZero)
        guard let seconds = Int64(exactly: wholeSeconds) else { return nil }

        let fractionalSeconds = mpvSeconds - wholeSeconds
        let attosecondsValue = (fractionalSeconds * 1e18).rounded()
        guard let attoseconds = Int64(exactly: attosecondsValue) else { return nil }

        self.init(
            secondsComponent: seconds,
            attosecondsComponent: attoseconds
        )
    }

    /// Clamps negative durations to zero.
    var clampPositiveOrZero: Duration {
        max(.zero, self)
    }

    /// Floating-point seconds for scalar APIs such as sliders.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
