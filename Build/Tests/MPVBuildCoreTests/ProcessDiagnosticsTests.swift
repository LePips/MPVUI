@testable import MPVBuildCore
import Testing

struct ProcessDiagnosticsTests {

    @Test
    func `early Swift assertions survive a long successful tail`() {
        let assertions = (1 ... 6).map { "Test \"case \($0)\" recorded an issue at Tests.swift:\($0):13: Expectation failed: false" }
        let output = assertions.joined(separator: "\n") + String(repeating: "\npassed unrelated work", count: 2000)
        let excerpt = ProcessDiagnostics.excerpt(output)
        for assertion in assertions {
            #expect(excerpt.contains(assertion))
        }
        #expect(excerpt.count < 12000)
    }

    @Test
    func `compiler diagnostics retain source context and disclose truncation`() {
        let output = (1 ... 30).map { "File.swift:\($0):2: error: cannot convert value\nlet x = value\n        ^" }.joined(separator: "\n")
        let excerpt = ProcessDiagnostics.excerpt(output)

        #expect(excerpt.contains("File.swift:1:2: error:"))
        #expect(excerpt.contains("let x = value"))
        #expect(excerpt.contains("additional diagnostics omitted"))
    }

    @Test
    func `unrecognized failures retain a bounded fallback`() {
        let excerpt = ProcessDiagnostics.excerpt(String(repeating: "noise", count: 3000) + "\nterminated by signal")

        #expect(excerpt.contains("No recognized diagnostic"))
        #expect(excerpt.hasSuffix("terminated by signal"))
        #expect(excerpt.count < 6100)
    }
}
