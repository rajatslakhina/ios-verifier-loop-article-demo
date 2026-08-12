import XCTest
@testable import VerifierLoop

final class FailureFingerprintTests: XCTestCase {

    /// The same failure, twice, from two different checkouts on two different
    /// simulators. A loop comparing raw strings sees two new problems and
    /// retries. A loop comparing fingerprints sees one and stops.
    func testSameFailureFromDifferentCheckoutsFingerprintsIdentically() {
        let first = FailureFingerprint(
            signalID: "xcuitest-smoke",
            rawEvidence: "/Users/rajat/DerivedData/App/Build/CheckoutTests.swift:88 failed on 4C9B1E20-3A11-4F5E-9C31-A0B2C3D4E5F6 at 09:14:02.418 addr 0x00007ff8"
        )
        let second = FailureFingerprint(
            signalID: "xcuitest-smoke",
            rawEvidence: "/Users/ci-runner/work/DerivedData/App/Build/CheckoutTests.swift:88 failed on 9F1A2B30-4C22-5D6E-8A42-B1C2D3E4F5A6 at 17:02:55.003 addr 0x00007fa1"
        )
        XCTAssertEqual(first, second)
    }

    func testGenuinelyDifferentFailuresStayDifferent() {
        let checkout = FailureFingerprint(signalID: "unit-suite", rawEvidence: "CheckoutTests.swift:88 assertion failed")
        let cart = FailureFingerprint(signalID: "unit-suite", rawEvidence: "CartTests.swift:12 assertion failed")
        XCTAssertNotEqual(checkout, cart)
    }

    func testSameEvidenceFromDifferentSignalsStaysDifferent() {
        let fromUnit = FailureFingerprint(signalID: "unit-suite", rawEvidence: "timeout")
        let fromUI = FailureFingerprint(signalID: "xcuitest-smoke", rawEvidence: "timeout")
        XCTAssertNotEqual(fromUnit, fromUI)
    }

    func testNormalisesAbsolutePathsToTheirLastComponent() {
        XCTAssertEqual(
            FailureFingerprint.normalize("/Users/rajat/src/App/Sources/Cart.swift"),
            "<path>/Cart.swift"
        )
    }

    func testNormalisesUDIDsTimestampsAddressesAndLongNumbers() {
        XCTAssertEqual(FailureFingerprint.normalize("4C9B1E20-3A11-4F5E-9C31-A0B2C3D4E5F6"), "<udid>")
        XCTAssertEqual(FailureFingerprint.normalize("09:14:02.418"), "<time>")
        XCTAssertEqual(FailureFingerprint.normalize("09:14:02"), "<time>")
        XCTAssertEqual(FailureFingerprint.normalize("0x00007ff8"), "<addr>")
        XCTAssertEqual(FailureFingerprint.normalize("1754923184"), "<num>")
    }

    /// Short numbers are line numbers and counts. Collapsing those would make
    /// two genuinely different failures look like one, which is the more
    /// expensive mistake.
    func testShortNumbersSurviveNormalisation() {
        XCTAssertEqual(FailureFingerprint.normalize("88"), "88")
        XCTAssertEqual(FailureFingerprint.normalize("1234"), "1234")
        XCTAssertEqual(FailureFingerprint.normalize("12345"), "<num>")
    }

    func testCollapsesRunsOfWhitespace() {
        XCTAssertEqual(FailureFingerprint.normalize("  a \t\n  b  "), "a b")
    }

    func testEmptyEvidenceIsHandledWithoutCrashing() {
        XCTAssertEqual(FailureFingerprint.normalize(""), "")
        XCTAssertEqual(FailureFingerprint.normalize("   "), "")
        let fingerprint = FailureFingerprint(signalID: "unit-suite", rawEvidence: "")
        XCTAssertEqual(fingerprint.description, "unit-suite#")
    }

    /// A malformed UDID must not be swallowed — five groups of the wrong widths
    /// is a different string, not a simulator identifier.
    func testNearMissUDIDIsNotCollapsed() {
        XCTAssertEqual(FailureFingerprint.normalize("4C9B1E2-3A11-4F5E-9C31-A0B2C3D4E5F6"),
                       "4C9B1E2-3A11-4F5E-9C31-A0B2C3D4E5F6")
        XCTAssertEqual(FailureFingerprint.normalize("4C9B1E2Z-3A11-4F5E-9C31-A0B2C3D4E5F6"),
                       "4C9B1E2Z-3A11-4F5E-9C31-A0B2C3D4E5F6")
    }

    func testNearMissTimestampIsNotCollapsed() {
        XCTAssertEqual(FailureFingerprint.normalize("9:14:02"), "9:14:02")
        XCTAssertEqual(FailureFingerprint.normalize("09:14"), "09:14")
    }

    func testTrailingSlashPathDoesNotCrash() {
        XCTAssertEqual(FailureFingerprint.normalize("/"), "<path>/PATH")
    }
}
