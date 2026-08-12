import XCTest
@testable import VerifierLoop

final class EvidenceLedgerTests: XCTestCase {

    private let prior = 0.35

    func testEmptyLedgerReturnsPrior() {
        XCTAssertEqual(EvidenceLedger(prior: prior).residualRisk, prior, accuracy: 1e-12)
        XCTAssertEqual(EvidenceLedger(prior: prior).elapsedSeconds, 0)
        XCTAssertEqual(EvidenceLedger(prior: prior).evidenceDecibans, 0, accuracy: 1e-12)
    }

    func testPriorIsClampedRatherThanTrusted() {
        XCTAssertEqual(EvidenceLedger(prior: 1.8).prior, 1.0)
        XCTAssertEqual(EvidenceLedger(prior: -3.0).prior, 0.0)
    }

    func testCertainPriorsAreAbsorbing() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        let reading = SignalReading(signal: unit, outcome: .passed)
        XCTAssertEqual(EvidenceLedger(prior: 0).recording(reading).residualRisk, 0)
        XCTAssertEqual(EvidenceLedger(prior: 1).recording(reading).residualRisk, 1)
    }

    /// The headline figure. Lint, build, a UI smoke pack and a screenshot all
    /// green still leaves a one-in-six chance the change is broken.
    func testLegacyLadderAllGreenLeaves16Percent() throws {
        let risk = try IOSSignalCatalog.legacyLadder().riskFloor(prior: prior)
        XCTAssertEqual(risk, 0.1664, accuracy: 0.0001)
    }

    /// The same prior, 128 seconds instead of 380, and it clears the bar.
    func testEngineeredLadderAllGreenLeaves3Point8Percent() throws {
        let risk = try IOSSignalCatalog.engineeredLadder().riskFloor(prior: prior)
        XCTAssertEqual(risk, 0.0378, accuracy: 0.0001)
    }

    func testInconclusiveContributesNothingButStillCostsTime() throws {
        let ui = try IOSSignalCatalog.uiSmoke()
        var ledger = EvidenceLedger(prior: prior)
        ledger.record(SignalReading(signal: ui, outcome: .inconclusive(reason: "simulator never booted")))
        XCTAssertEqual(ledger.residualRisk, prior, accuracy: 1e-12)
        XCTAssertEqual(ledger.elapsedSeconds, 240)
        XCTAssertEqual(ledger.theatreSeconds, 240)
    }

    func testTheatreSecondsCountsOnlyZeroInformationReadings() throws {
        let shot = try IOSSignalCatalog.blindScreenshot()
        let unit = try IOSSignalCatalog.unitSuite()
        var ledger = EvidenceLedger(prior: prior)
        ledger.record(SignalReading(signal: unit, outcome: .passed))
        ledger.record(SignalReading(signal: shot, outcome: .passed))
        XCTAssertEqual(ledger.elapsedSeconds, 123)
        XCTAssertEqual(ledger.theatreSeconds, 95)
    }

    func testFailureRaisesRiskAndPassLowersIt() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        let failed = EvidenceLedger(prior: prior)
            .recording(SignalReading(signal: unit, outcome: .failed(evidence: "boom")))
        let passed = EvidenceLedger(prior: prior)
            .recording(SignalReading(signal: unit, outcome: .passed))
        XCTAssertGreaterThan(failed.residualRisk, prior)
        XCTAssertLessThan(passed.residualRisk, prior)
    }

    func testEvidenceIsOrderIndependent() throws {
        let signals = try IOSSignalCatalog.engineeredLadder().signals
        var forward = EvidenceLedger(prior: prior)
        var backward = EvidenceLedger(prior: prior)
        for signal in signals {
            forward.record(SignalReading(signal: signal, outcome: .passed))
        }
        for signal in signals.reversed() {
            backward.record(SignalReading(signal: signal, outcome: .passed))
        }
        XCTAssertEqual(forward.residualRisk, backward.residualRisk, accuracy: 1e-12)
    }

    func testAnInfiniteFailureRatioSaturatesRatherThanProducingNaN() throws {
        let certain = try VerificationSignal(
            id: "certain", kind: .compile, legibility: .machineReadable,
            latencySeconds: 5, sensitivity: 0.9, falseAlarmRate: 0.0
        )
        let ledger = EvidenceLedger(prior: prior)
            .recording(SignalReading(signal: certain, outcome: .failed(evidence: "type error")))
        XCTAssertEqual(ledger.residualRisk, 1.0)
        XCTAssertFalse(ledger.residualRisk.isNaN)
    }
}
