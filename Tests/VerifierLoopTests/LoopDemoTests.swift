import XCTest
@testable import VerifierLoop

final class LoopDemoTests: XCTestCase {

    func testDemoBuildsWithoutThrowing() throws {
        XCTAssertNoThrow(try LoopDemo())
    }

    func testHeadlineRatiosAreWhatTheArticleClaims() throws {
        let demo = try LoopDemo()
        XCTAssertEqual(demo.wallClockRatio, 2.97, accuracy: 0.01)
        XCTAssertEqual(demo.residualRiskRatio, 4.41, accuracy: 0.01)
    }

    func testDemoAuditsAgreeWithTheLadders() throws {
        let demo = try LoopDemo()
        XCTAssertEqual(demo.legacyAudit.riskFloor, 0.1664, accuracy: 0.0001)
        XCTAssertEqual(demo.engineeredAudit.riskFloor, 0.0378, accuracy: 0.0001)
        XCTAssertFalse(demo.legacyAudit.clearsThreshold)
        XCTAssertTrue(demo.engineeredAudit.clearsThreshold)
    }

    func testRankingIsSortedByEvidencePerSecond() throws {
        let demo = try LoopDemo()
        XCTAssertEqual(demo.rankedSignals.first?.id, "swiftlint+macro-preflight")
        XCTAssertEqual(demo.rankedSignals.last?.id, "sim-screenshot")
        let densities = demo.rankedSignals.map(\.passEvidencePerSecond)
        for index in 1..<densities.count {
            XCTAssertGreaterThanOrEqual(densities[index - 1], densities[index])
        }
    }

    func testGatedOutcomeEscalatesEvenThoughTheLadderIsIdentical() throws {
        let demo = try LoopDemo()
        let outcome = demo.gatedOutcome()
        guard case let .escalate(requirement) = outcome.verdict else {
            return XCTFail("expected escalate, got \(outcome.verdict)")
        }
        XCTAssertEqual(requirement.blockedBy, [.projectFile])
        XCTAssertEqual(outcome.ledger.elapsedSeconds, 0)
    }

    func testAllGreenOutcomesMatchTheTwoStories() throws {
        let demo = try LoopDemo()
        guard case .close = demo.allGreenOutcome(for: demo.engineered).verdict else {
            return XCTFail("engineered ladder should close")
        }
        guard case .park(.unreachableThreshold) = demo.allGreenOutcome(for: demo.legacy).verdict else {
            return XCTFail("legacy ladder should park")
        }
    }

    func testFormattingHelpersRenderTheWayTheUIExpects() {
        XCTAssertEqual(LoopFormat.percent(0.037768), "3.8%")
        XCTAssertEqual(LoopFormat.percent(0.166380), "16.6%")
        XCTAssertEqual(LoopFormat.seconds(128), "2m 8s")
        XCTAssertEqual(LoopFormat.seconds(42), "42s")
        XCTAssertEqual(LoopFormat.seconds(380), "6m 20s")
        XCTAssertEqual(LoopFormat.multiple(2.96875), "3.0×")
        XCTAssertEqual(LoopFormat.multiple(.infinity), "∞")
    }

    func testParkReasonsDescribeThemselvesUsefully() {
        let reason = ParkReason.unreachableThreshold(bestAchievable: 0.16638, threshold: 0.05)
        XCTAssertEqual(reason.description, "Ladder cannot reach 5.0% even fully green — floor is 16.6%.")
    }
}
