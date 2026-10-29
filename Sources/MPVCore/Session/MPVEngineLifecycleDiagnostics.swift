/// Internal counters used by integration tests to distinguish an in-place
/// output resize from a player teardown and media reload.
package struct MPVEngineLifecycleDiagnostics: Equatable, Sendable {

    package var engineActivity = MPVPlaybackDiagnostics.EngineActivity()
    package var handlesCreated: UInt64 = 0
    package var handlesDestroyed: UInt64 = 0
    package var loadCommands: UInt64 = 0
    package var startFileEvents: UInt64 = 0
    package var seekCommands: UInt64 = 0
    package var surfaceResizeCommands: UInt64 = 0
    package var liveColorUpdates: UInt64 = 0
    package var loadingStateTransitions: UInt64 = 0
    package var bufferingStateTransitions: UInt64 = 0
    package var seekingStateTransitions: UInt64 = 0

    package init() {}
}
