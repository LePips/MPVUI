@testable import MPVUI
import Testing

@Suite(.tags(.unit, .hdr))
struct MPVTransferFunctionTests {
    struct Signal: Sendable {
        let aliases: [String]
        let transfer: MPVTransferFunction
        let canonical: String
        var hdr = false
    }

    static let signals: [Signal] = [
        .init(aliases: ["bt.709", "bt709"], transfer: .bt709, canonical: "bt.709"),
        .init(aliases: ["bt.1886", "bt1886"], transfer: .bt1886, canonical: "bt.1886"),
        .init(aliases: ["srgb"], transfer: .sRGB, canonical: "srgb"),
        .init(aliases: ["linear"], transfer: .linear, canonical: "linear"),
        .init(aliases: ["gamma1.8", "gamma18"], transfer: .gamma18, canonical: "gamma1.8"),
        .init(aliases: ["gamma2.0", "gamma20"], transfer: .gamma20, canonical: "gamma2.0"),
        .init(aliases: ["gamma2.2", "gamma22"], transfer: .gamma22, canonical: "gamma2.2"),
        .init(aliases: ["gamma2.4", "gamma24"], transfer: .gamma24, canonical: "gamma2.4"),
        .init(aliases: ["gamma2.6", "gamma26"], transfer: .gamma26, canonical: "gamma2.6"),
        .init(aliases: ["gamma2.8", "gamma28"], transfer: .gamma28, canonical: "gamma2.8"),
        .init(aliases: ["pq", "st2084", "smpte2084", "smpte-st-2084", "smpte-st2084"], transfer: .pq, canonical: "pq", hdr: true),
        .init(aliases: ["hlg", "arib-std-b67", "arib-std-b-67"], transfer: .hlg, canonical: "hlg", hdr: true),
    ]

    @Test(arguments: signals)
    func `mpv aliases normalize case and whitespace without changing dynamic range`(signal: Signal) {
        for alias in signal.aliases {
            let parsed = MPVTransferFunction(mpvValue: " \t\(alias.uppercased())\n")
            #expect(parsed == signal.transfer)
            #expect(parsed.mpvValue == signal.canonical)
            #expect(parsed.isHDR == signal.hdr)
        }
    }

    @Test(arguments: [nil, "", " \n\t"] as [String?])
    func `missing transfer metadata remains unknown`(raw: String?) {
        let transfer = MPVTransferFunction(mpvValue: raw)
        #expect(transfer == .unknown)
        #expect(transfer.mpvValue == nil)
        #expect(!transfer.isHDR)
    }

    @Test
    func `future transfer names preserve spelling without claiming HDR`() {
        let transfer = MPVTransferFunction(mpvValue: " FutureHDRCurve \n")
        #expect(transfer == .other("FutureHDRCurve"))
        #expect(transfer.mpvValue == "FutureHDRCurve")
        #expect(!transfer.isHDR)
    }
}
