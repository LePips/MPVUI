extension Double {
    /// Returns the value if it is finite and nonnegative, or `nil` otherwise.
    var positiveOrZero: Double? {
        guard isFinite, self >= 0 else { return nil }
        return self
    }
}
