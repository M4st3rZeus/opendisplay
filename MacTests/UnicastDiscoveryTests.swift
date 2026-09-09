import XCTest

/// The PTR response parser. Hand-rolled DNS wire parsing on data straight off
/// the network, so it has to survive truncation and malformed input without
/// trapping — a crash here would take the sender down whenever some unrelated
/// device on the LAN answered oddly.
final class UnicastDiscoveryTests: XCTestCase {

    /// A minimal `_opensidecar._tcp.local` PTR response advertising `name`.
    private func response(instance: String, answers: Int = 1) -> Data {
        var d = Data([0x00, 0x00, 0x84, 0x00, 0x00, 0x01])
        d.append(contentsOf: [UInt8(answers >> 8), UInt8(answers & 0xFF)])
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // Question, echoed.
        for label in ["_opensidecar", "_tcp", "local"] {
            d.append(UInt8(label.utf8.count)); d.append(contentsOf: Array(label.utf8))
        }
        d.append(0x00)
        d.append(contentsOf: [0x00, 0x0C, 0x00, 0x01])
        // Answer: same name, PTR, ttl, rdlength, then the instance name.
        for label in ["_opensidecar", "_tcp", "local"] {
            d.append(UInt8(label.utf8.count)); d.append(contentsOf: Array(label.utf8))
        }
        d.append(0x00)
        d.append(contentsOf: [0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x11, 0x94])
        var rdata = Data()
        for label in [instance, "_opensidecar", "_tcp", "local"] {
            rdata.append(UInt8(label.utf8.count)); rdata.append(contentsOf: Array(label.utf8))
        }
        rdata.append(0x00)
        d.append(contentsOf: [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)])
        d.append(rdata)
        return d
    }

    /// A real response captured from an iPhone on the network the unicast
    /// sweep exists for.
    ///
    /// The synthetic fixtures below write every name inline, which is legal
    /// but not what responders actually send: here the answer's name is a
    /// compression pointer (`c00c`). The parser mis-stepped on exactly that
    /// and read rdlength as 77 instead of 28, so the sweep found nothing
    /// while a hand-run `dig` worked. Captured bytes are the only fixture
    /// that would have caught it.
    func testParsesARealResponseWithCompressedNames() {
        let hex = "0000840000010001000000040c5f6f70656e73696465636172045f7463700"
            + "56c6f63616c00000c0001c00c000c00010000000a001f1c4d3424743372e2809"
            + "97320695068"
            + "6f6e652031362050726f204d6178c00c"
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        XCTAssertEqual(UnicastDiscovery.instanceName(in: data),
                       "M4$t3r\u{2019}s iPhone 16 Pro Max")
    }

    func testExtractsTheInstanceName() {
        XCTAssertEqual(UnicastDiscovery.instanceName(in: response(instance: "My iPhone")),
                       "My iPhone")
    }

    func testNameWithSpacesAndPunctuationSurvives() {
        // Real device names: "M4$t3r's iPhone 16 Pro Max".
        let name = "M4$t3r’s iPhone 16 Pro Max"
        XCTAssertEqual(UnicastDiscovery.instanceName(in: response(instance: name)), name)
    }

    func testZeroAnswersIsNotADevice() {
        // A responder that knows the type but advertises nothing.
        XCTAssertNil(UnicastDiscovery.instanceName(in: response(instance: "x", answers: 0)))
    }

    func testTruncatedResponsesAreRejectedNotCrashed() {
        let full = response(instance: "My iPhone")
        for length in 0..<full.count {
            _ = UnicastDiscovery.instanceName(in: full.prefix(length))
        }
        // Reaching here without trapping is the assertion.
        XCTAssertNil(UnicastDiscovery.instanceName(in: Data()))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(UnicastDiscovery.instanceName(in: Data([0xFF, 0xFF, 0xFF])))
        XCTAssertNil(UnicastDiscovery.instanceName(in: Data(repeating: 0xAA, count: 64)))
    }
}
