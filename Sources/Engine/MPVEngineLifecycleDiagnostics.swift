/// Internal counters used by integration tests to distinguish an in-place
/// output resize from a player teardown and media reload.
struct MPVEngineLifecycleDiagnostics: Equatable, Sendable {
    var handlesCreated: UInt64 = 0
    var handlesDestroyed: UInt64 = 0
    var loadCommands: UInt64 = 0
    var startFileEvents: UInt64 = 0
    var seekCommands: UInt64 = 0
    var surfaceResizeCommands: UInt64 = 0
    var loadingStateTransitions: UInt64 = 0
    var bufferingStateTransitions: UInt64 = 0
    var seekingStateTransitions: UInt64 = 0
}
