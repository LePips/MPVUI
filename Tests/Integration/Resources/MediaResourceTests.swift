import CryptoKit
import Foundation
import MPVUITestResources
import Testing

@Suite(.tags(.integration))
struct MediaResourceTests {
    @Test(arguments: [false, true])
    func `bundled media resources match checksums`(testOnly: Bool) throws {
        let bundle = testOnly ? Bundle.module : TestResources.bundle
        let manifest = try #require(bundle.url(forResource: "Fixtures.lock", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        #expect(!fixtures.isEmpty)
        for (name, expected) in fixtures {
            let url = try #require(bundle.url(forResource: name, withExtension: nil, subdirectory: "Media"))
            let data = try Data(contentsOf: url)
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(checksum == expected, "Bundled media checksum mismatch: \(name)")
        }
    }
}
