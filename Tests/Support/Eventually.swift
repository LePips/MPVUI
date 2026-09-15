import Foundation
import Testing

/// Waits for an observable outcome, retaining the assertion's call-site location.
/// The predicate may read actor-isolated state and must not mutate the system.
@MainActor
func eventually(
    _ description: String,
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(20),
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    _ predicate: @MainActor () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        try Task.checkCancellation()
        if try await predicate() {
            return
        }
        if clock.now >= deadline {
            break
        }
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: pollInterval)))
    }
    let location = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    try #require(Bool(false), "Timed out waiting for \(description).", sourceLocation: location)
}
