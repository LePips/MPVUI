extension Double {
    /// Returns the value if finite and nonnegative; otherwise `nil`.
    var positiveOrZero: Double? {
        guard isFinite, self >= 0 else { return nil }
        return self
    }
}
