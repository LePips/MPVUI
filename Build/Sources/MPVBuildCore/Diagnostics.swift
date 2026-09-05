import Foundation

final class BuildDiagnostics: @unchecked Sendable {
    struct Event: Codable { let stage: String
        let name: String
        let key: String
        let action: String
        let reason: String
        let seconds: Double
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private let started = Date()
    let explain: Bool
    init(explain: Bool) {
        self.explain = explain
    }

    func record(stage: String, name: String, key: String, action: String, reason: String, since start: Date) {
        let event = Event(stage: stage, name: name, key: key, action: action, reason: reason, seconds: Date().timeIntervalSince(start))
        lock.lock()
        events.append(event)
        lock.unlock()
        if explain {
            print("explain \(stage)/\(name): \(reason); \(action) \(key)")
        }
    }

    func save(to path: URL) throws {
        struct Report: Encodable { let schemaVersion: Int
            let elapsedSeconds: Double
            let events: [Event]
        }
        lock.lock()
        let snapshot = events
        lock.unlock()
        try write(Report(schemaVersion: 1, elapsedSeconds: Date().timeIntervalSince(started), events: snapshot), path)
    }
}
