extension Duration {
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
}
