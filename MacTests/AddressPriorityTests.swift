import XCTest

/// hello.addrs ordering. On a network where Bonjour resolves the service over
/// AWDL, the only addresses offered were fe80:: and 169.254.* — the sender
/// dialled those and never reached the peer, while its routable 192.168.x
/// address pinged fine.
final class AddressPriorityTests: XCTestCase {

    func testLinkLocalIsRecognised() {
        XCTAssertTrue(WireAddress.isLinkLocal("169.254.50.226"))
        XCTAssertTrue(WireAddress.isLinkLocal("fe80::1c6f:f43b:6a7c:7ed8"))
        XCTAssertTrue(WireAddress.isLinkLocal("FE80::1"))      // case-insensitive
        XCTAssertFalse(WireAddress.isLinkLocal("192.168.2.121"))
        XCTAssertFalse(WireAddress.isLinkLocal("2400:9820:1:12e6::1"))
        // 169.254 is only link-local as a /16 prefix; 169.253 is ordinary.
        XCTAssertFalse(WireAddress.isLinkLocal("169.253.1.1"))
    }

    func testRoutableAddressesComeFirst() {
        let ordered = WireAddress.prioritised([
            "fe80::1c6f:f43b:6a7c:7ed8",
            "169.254.50.226",
            "192.168.0.1",
        ])
        XCTAssertEqual(ordered.first, "192.168.0.1",
                       "a routable address must be offered before any link-local one")
        XCTAssertTrue(ordered.dropFirst().allSatisfy(WireAddress.isLinkLocal))
    }

    func testAllLinkLocalIsLeftAlone() {
        // Nothing routable to promote: still returns every candidate, because
        // link-local is better than offering none.
        let input = ["fe80::1", "169.254.1.1"]
        XCTAssertEqual(Set(WireAddress.prioritised(input)), Set(input))
    }

    func testEmptyAndSingleAreStable() {
        XCTAssertTrue(WireAddress.prioritised([]).isEmpty)
        XCTAssertEqual(WireAddress.prioritised(["192.168.1.5"]), ["192.168.1.5"])
    }
}
