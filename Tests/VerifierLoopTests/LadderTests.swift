import XCTest
@testable import VerifierLoop

final class LadderTests: XCTestCase {

    private let prior = 0.35
    private let threshold = 0.05

    func testLegacyLadderCostsThreeTimesTheEngineeredOne() throws {
        let legacy = try IOSSignalCatalog.legacyLadder()
        let engineered = try IOSSignalCatalog.engineeredLadder()
        XCTAssertEqual(legacy.totalLatencySeconds, 380)
        XCTAssertEqual(engineered.totalLatencySeconds, 128)
    }

    func testLegacyLadderCannotClearThresholdEvenFullyGreen() throws {
        let legacy = try IOSSignalCatalog.legacyLadder()
        XCTAssertFalse(legacy.canReach(threshold: threshold, prior: prior))
        XCTAssertNil(legacy.minimalGreenPrefix(threshold: threshold, prior: prior))
    }

    func testMinimalGreenPrefixRunsAllFourRungsInThisOrder() throws {
        let engineered = try IOSSignalCatalog.engineeredLadder()
        XCTAssertTrue(engineered.canReach(threshold: threshold, prior: prior))
        let prefix = engineered.minimalGreenPrefix(threshold: threshold, prior: prior)
        XCTAssertEqual(prefix?.map(\.id), ["swiftlint+macro-preflight", "swift-build", "unit-suite", "snapshot-diff"])
    }

    /// Three of the four rungs is not "close enough" — it lands at 7.4%,
    /// half again over the bar.
    func testDroppingTheSnapshotDiffPutsTheLadderBackOverThreshold() throws {
        let threeRung = try VerifierLadder(
            name: "three rungs",
            signals: [IOSSignalCatalog.lint(), IOSSignalCatalog.build(), IOSSignalCatalog.unitSuite()]
        )
        XCTAssertEqual(threeRung.riskFloor(prior: prior), 0.0743, accuracy: 0.0001)
        XCTAssertFalse(threeRung.canReach(threshold: threshold, prior: prior))
    }

    func testTheatreIsIdentifiedAndPriced() throws {
        let legacy = try IOSSignalCatalog.legacyLadder()
        XCTAssertEqual(legacy.theatreSignals.map(\.id), ["sim-screenshot"])
        XCTAssertEqual(legacy.theatreSeconds, 95)
        XCTAssertEqual(legacy.theatreSeconds / legacy.totalLatencySeconds, 0.25, accuracy: 1e-12)

        let engineered = try IOSSignalCatalog.engineeredLadder()
        XCTAssertTrue(engineered.theatreSignals.isEmpty)
        XCTAssertEqual(engineered.theatreSeconds, 0)
    }

    func testRemovingTheatreChangesCostButNotConclusion() throws {
        let legacy = try IOSSignalCatalog.legacyLadder()
        let trimmed = legacy.withoutTheatre()
        XCTAssertEqual(trimmed.totalLatencySeconds, 285)
        XCTAssertEqual(
            trimmed.riskFloor(prior: prior),
            legacy.riskFloor(prior: prior),
            accuracy: 1e-12
        )
    }

    func testEvidenceDensityOrderingPutsTheUnitSuiteSecond() throws {
        let all = try VerifierLadder(name: "all", signals: IOSSignalCatalog.all())
        XCTAssertEqual(all.orderedByEvidenceDensity().signals.map(\.id), [
            "swiftlint+macro-preflight",
            "unit-suite",
            "swift-build",
            "snapshot-diff",
            "xcuitest-smoke",
            "sim-screenshot"
        ])
    }

    func testOrderingIsStableAcrossRepeatedApplication() throws {
        let all = try VerifierLadder(name: "all", signals: IOSSignalCatalog.all())
        let once = all.orderedByEvidenceDensity()
        XCTAssertEqual(once.orderedByEvidenceDensity().signals, once.signals)
    }

    func testEmptyLadderIsInertRatherThanFatal() {
        let empty = VerifierLadder(name: "empty", signals: [])
        XCTAssertEqual(empty.totalLatencySeconds, 0)
        XCTAssertEqual(empty.riskFloor(prior: prior), prior, accuracy: 1e-12)
        XCTAssertNil(empty.minimalGreenPrefix(threshold: threshold, prior: prior))
        XCTAssertTrue(empty.orderedByEvidenceDensity().signals.isEmpty)
    }

    func testAuditReportsWhatTheLadderCostsAndWhatItBuys() throws {
        let legacyAudit = LadderAudit(
            ladder: try IOSSignalCatalog.legacyLadder(), prior: prior, threshold: threshold
        )
        XCTAssertEqual(legacyAudit.signalCount, 4)
        XCTAssertEqual(legacyAudit.totalLatencySeconds, 380)
        XCTAssertEqual(legacyAudit.theatreSeconds, 95)
        XCTAssertFalse(legacyAudit.clearsThreshold)
        XCTAssertTrue(legacyAudit.minimalGreenPrefixIDs.isEmpty)
        XCTAssertEqual(legacyAudit.wastedGreenSeconds, 0)

        let engineeredAudit = LadderAudit(
            ladder: try IOSSignalCatalog.engineeredLadder(), prior: prior, threshold: threshold
        )
        XCTAssertTrue(engineeredAudit.clearsThreshold)
        XCTAssertEqual(engineeredAudit.prefixSeconds, 128)
        XCTAssertEqual(engineeredAudit.wastedGreenSeconds, 0)
    }

    /// A ladder padded with confirmation after it has already cleared the bar
    /// should price that padding.
    func testAuditPricesConfirmationAfterTheThresholdIsMet() throws {
        let padded = try VerifierLadder(
            name: "padded",
            signals: IOSSignalCatalog.engineeredLadder().signals + [IOSSignalCatalog.uiSmoke()]
        )
        let audit = LadderAudit(ladder: padded, prior: prior, threshold: threshold)
        XCTAssertEqual(audit.totalLatencySeconds, 368)
        XCTAssertEqual(audit.prefixSeconds, 128)
        XCTAssertEqual(audit.wastedGreenSeconds, 240)
    }
}
