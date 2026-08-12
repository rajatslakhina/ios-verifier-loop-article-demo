import XCTest
@testable import VerifierLoop

/// Every number quoted in the write-up that accompanies this repo, asserted
/// here so that prose and code cannot drift apart silently.
///
/// If you change a rate in `IOSSignalCatalog`, this file is what tells you
/// which published sentence just became wrong.
final class ArticleClaimsTests: XCTestCase {

    private let prior = 0.35
    private let threshold = 0.05

    // MARK: - Policy constants quoted as "a third" and "5%"

    func testStandardPolicyMatchesThePublishedPriorAndBar() {
        XCTAssertEqual(LoopPolicy.standard.prior, 0.35, accuracy: 1e-12)
        XCTAssertEqual(LoopPolicy.standard.closeThreshold, 0.05, accuracy: 1e-12)
    }

    func testUISmokeCriesWolfOnTwentyTwoPercentOfCleanRuns() throws {
        XCTAssertEqual(try IOSSignalCatalog.uiSmoke().falseAlarmRate, 0.22, accuracy: 1e-12)
        XCTAssertEqual(try IOSSignalCatalog.uiSmoke().latencySeconds, 240, accuracy: 1e-12)
    }

    // MARK: - Every bar in the evidence-per-second chart

    func testEvidencePerSecondBarValues() throws {
        let expected: [String: Double] = [
            "swiftlint+macro-preflight": 0.020602,
            "unit-suite": 0.018202,
            "swift-build": 0.006078,
            "snapshot-diff": 0.005647,
            "xcuitest-smoke": 0.000475,
            "sim-screenshot": 0.000000
        ]
        for signal in try IOSSignalCatalog.all() {
            guard let want = expected[signal.id] else {
                return XCTFail("unexpected signal id \(signal.id)")
            }
            XCTAssertEqual(signal.passEvidencePerSecond, want, accuracy: 5e-7, signal.id)
        }
    }

    // MARK: - The risk-descent chart, point by point

    private func cumulativeRisk(_ ladder: VerifierLadder) -> [Double] {
        var ledger = EvidenceLedger(prior: prior)
        var out = [ledger.residualRisk]
        for signal in ladder.signals {
            ledger.record(SignalReading(signal: signal, outcome: .passed))
            out.append(ledger.residualRisk)
        }
        return out
    }

    func testLegacyDescentMatchesThePublishedChart() throws {
        let points = cumulativeRisk(try IOSSignalCatalog.legacyLadder())
        let want = [0.350000, 0.318352, 0.206011, 0.166380, 0.166380]
        XCTAssertEqual(points.count, want.count)
        for (got, expect) in zip(points, want) {
            XCTAssertEqual(got, expect, accuracy: 5e-7)
        }
    }

    func testEngineeredDescentMatchesThePublishedChart() throws {
        let points = cumulativeRisk(try IOSSignalCatalog.engineeredLadder())
        let want = [0.350000, 0.318352, 0.206011, 0.074285, 0.037768]
        XCTAssertEqual(points.count, want.count)
        for (got, expect) in zip(points, want) {
            XCTAssertEqual(got, expect, accuracy: 5e-7)
        }
    }

    /// "Both ladders spend their first 45 seconds identically."
    func testBothLaddersShareTheirFirstFortyFiveSeconds() throws {
        let legacy = try IOSSignalCatalog.legacyLadder().signals
        let engineered = try IOSSignalCatalog.engineeredLadder().signals
        XCTAssertEqual(legacy[0], engineered[0])
        XCTAssertEqual(legacy[1], engineered[1])
        XCTAssertEqual(legacy[0].latencySeconds + legacy[1].latencySeconds, 45)
        XCTAssertEqual(cumulativeRisk(try IOSSignalCatalog.legacyLadder())[2],
                       cumulativeRisk(try IOSSignalCatalog.engineeredLadder())[2],
                       accuracy: 1e-12)
    }

    /// The two annotations on the chart: 28s buys 13.2 points, 240s buys 4.0.
    func testAnnotatedPointDeltas() throws {
        let legacy = cumulativeRisk(try IOSSignalCatalog.legacyLadder())
        let engineered = cumulativeRisk(try IOSSignalCatalog.engineeredLadder())
        XCTAssertEqual((engineered[2] - engineered[3]) * 100, 13.2, accuracy: 0.05)
        XCTAssertEqual((legacy[2] - legacy[3]) * 100, 4.0, accuracy: 0.05)
    }

    // MARK: - "Which rungs are actually load-bearing?"

    /// The honest leave-one-out. Three of the four rungs are load-bearing;
    /// the 3-second lint is not, and the write-up says so.
    func testLeaveOneOutIdentifiesTheOnlyOptionalRung() throws {
        let demo = try LoopDemo()
        let expected: [(String, Double, Bool)] = [
            ("swiftlint+macro-preflight", 0.043290, true),
            ("swift-build", 0.065987, false),
            ("unit-suite", 0.112619, false),
            ("snapshot-diff", 0.074285, false)
        ]
        for (id, want, stillClears) in expected {
            guard let signal = demo.engineered.signals.first(where: { $0.id == id }) else {
                return XCTFail("missing rung \(id)")
            }
            let risk = demo.engineeredRiskWithout(signal)
            XCTAssertEqual(risk, want, accuracy: 5e-6, id)
            XCTAssertEqual(risk <= threshold, stillClears, id)
        }
    }

    // MARK: - Ratios quoted in both pieces

    func testQuotedRatios() throws {
        let demo = try LoopDemo()
        XCTAssertEqual(demo.wallClockRatio, 2.96875, accuracy: 1e-9)
        XCTAssertEqual(demo.residualRiskRatio, 4.4053, accuracy: 5e-5)
        XCTAssertEqual(demo.legacy.theatreSeconds / demo.legacy.totalLatencySeconds,
                       0.25, accuracy: 1e-12)
        let unit = try IOSSignalCatalog.unitSuite()
        let ui = try IOSSignalCatalog.uiSmoke()
        XCTAssertEqual(unit.passEvidencePerSecond / ui.passEvidencePerSecond, 38.34, accuracy: 0.01)
    }

    /// The gate fires before a single second is spent, on the same all-green run.
    func testGatedRunEscalatesWithNothingSpent() throws {
        let demo = try LoopDemo()
        let (verdict, ledger) = demo.gatedOutcome()
        guard case let .escalate(requirement) = verdict else {
            return XCTFail("expected escalate, got \(verdict)")
        }
        XCTAssertEqual(requirement.blockedBy, [.projectFile])
        XCTAssertEqual(ledger.elapsedSeconds, 0)
        XCTAssertTrue(ledger.readings.isEmpty)
    }

    /// Guards the "62 tests" style claim from silently going stale: the demo
    /// surface the write-up describes is exactly these six public entry points.
    func testDemoSurfaceIsWhatThePieceDescribes() throws {
        let demo = try LoopDemo()
        XCTAssertEqual(demo.legacy.signals.count, 4)
        XCTAssertEqual(demo.engineered.signals.count, 4)
        XCTAssertEqual(demo.rankedSignals.count, 6)
        XCTAssertEqual(demo.legacy.totalLatencySeconds, 380)
        XCTAssertEqual(demo.engineered.totalLatencySeconds, 128)
    }
}
