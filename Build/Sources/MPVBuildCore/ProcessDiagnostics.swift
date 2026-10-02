import Foundation

enum ProcessDiagnostics {
    /// Selects compiler and Swift Testing failures even when later output is noisy.
    static func excerpt(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        let pattern = #"\berror:|\bfatal error\b|recorded an issue|Expectation failed|AssertionError|Traceback \(most recent"#
        var seen = Set<String>()
        let matches = lines.indices.filter { index in
            let line = lines[index]
            return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil && seen.insert(line).inserted
        }
        guard !matches.isEmpty else {
            return "No recognized diagnostic; final output follows:\n" + output.suffix(6000)
        }
        var snippets: [String] = []
        var characters = 0
        for index in matches.prefix(20) {
            let snippet = "combined output line \(index + 1):\n" + lines[max(0, index - 1) ... min(lines.count - 1, index + 2)]
                .joined(separator: "\n")
            let bounded = String(snippet.prefix(2000)) + (snippet.count > 2000 ? "\n[excerpt truncated]" : "")
            if characters + bounded.count > 12000 {
                break
            }
            snippets.append(bounded)
            characters += bounded.count
        }
        if matches.count > snippets.count {
            snippets.append("\(matches.count - snippets.count) additional diagnostics omitted; see full log.")
        }
        return snippets.joined(separator: "\n\n")
    }
}
