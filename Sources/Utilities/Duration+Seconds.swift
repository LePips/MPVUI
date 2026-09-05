public extension Duration {
    /// The duration represented as a floating-point number of seconds.
    ///
    /// Use this when adapting a ``Duration`` to an API that requires a scalar
    /// seconds value, such as a slider or a media-engine boundary.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
