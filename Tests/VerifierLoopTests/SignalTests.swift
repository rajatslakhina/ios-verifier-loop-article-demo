import XCTest
@testable import VerifierLoop

final class SignalTests: XCTestCase {

    func testRejectsSensitivityOutsideUnitInterval() {
        XCTAssertThrowsError(try VerificationSignal(
            id: "bad", kind: .unitTest, legibility: .machineReadable,
            latencySeconds: 1, sensitivity: 1.4, falseAlarmRate: 0.1
        )) { error in
            XCTAssertEqual(
                error as? SignalDefinitionError,
                .rateOutOfRange(field: "sensitivity", value: 1.4)
            )
        }
    }

    func testRejectsFalseAlarmRateOutsideUnitInterval() {
        XCTAssertThrowsError(try VerificationSignal(
            id: "bad", kind: .unitTest, legibility: .machineReadable,
            latencySeconds: 1, sensitivity: 0.5, falseAlarmRate: -0.01
        )) { error in
            XCTAssertEqual(
                error as? SignalDefinitionError,
                .rateOutOfRange(field: "falseAlarmRate", value: -0.01)
            )
        }
    }

    func testRejectsZeroLatency() {
        XCTAssertThrowsError(try VerificationSignal(
            id: "bad", kind: .unitTest, legibility: .machineReadable,
            latencySeconds: 0, sensitivity: 0.5, falseAlarmRate: 0.1
        )) { error in
            XCTAssertEqual(error as? SignalDefinitionError, .nonPositiveLatency(0))
        }
    }

    /// The load-bearing claim of the whole library: a signal whose sensitivity
    /// equals its false-alarm rate contributes a likelihood ratio of exactly 1
    /// on a pass. Not "close to". Exactly.
    func testBlindScreenshotPassIsExactlyZeroEvidence() throws {
        let shot = try IOSSignalCatalog.blindScreenshot()
        XCTAssertFalse(shot.isInformative)
        XCTAssertEqual(shot.passLikelihoodRatio, 1.0, accuracy: 1e-12)
        XCTAssertEqual(shot.failLikelihoodRatio, 1.0, accuracy: 1e-12)
        XCTAssertEqual(shot.passEvidencePerSecond, 0.0, accuracy: 1e-12)
    }

    func testInformativeSignalsAreFlaggedInformative() throws {
        for signal in try IOSSignalCatalog.all() where signal.id != "sim-screenshot" {
            XCTAssertTrue(signal.isInformative, "\(signal.id) should be informative")
            XCTAssertLessThan(signal.passLikelihoodRatio, 1.0, "\(signal.id)")
            XCTAssertGreaterThan(signal.failLikelihoodRatio, 1.0, "\(signal.id)")
        }
    }

    func testLikelihoodRatiosMatchHandComputedValues() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        // (1 - 0.70) / (1 - 0.03)
        XCTAssertEqual(unit.passLikelihoodRatio, 0.30 / 0.97, accuracy: 1e-12)
        // 0.70 / 0.03
        XCTAssertEqual(unit.failLikelihoodRatio, 0.70 / 0.03, accuracy: 1e-12)
    }

    /// The number that reorders the ladder: the unit suite buys roughly 38× as
    /// much belief per second as the four-minute UI pack.
    func testUnitSuiteOutperformsUISmokePerSecond() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        let ui = try IOSSignalCatalog.uiSmoke()
        let ratio = unit.passEvidencePerSecond / ui.passEvidencePerSecond
        XCTAssertEqual(ratio, 38.34, accuracy: 0.01)
    }

    func testZeroFalseAlarmRateGivesInfiniteFailureEvidence() throws {
        let perfect = try VerificationSignal(
            id: "perfect", kind: .compile, legibility: .machineReadable,
            latencySeconds: 10, sensitivity: 0.5, falseAlarmRate: 0.0
        )
        XCTAssertEqual(perfect.failLikelihoodRatio, .infinity)
    }

    /// A detector that always fires cannot produce a pass, so the pass branch
    /// must not silently divide by zero.
    func testAlwaysFiringSignalHasInfinitePassRatio() throws {
        let alwaysFires = try VerificationSignal(
            id: "always", kind: .uiTest, legibility: .noisyText,
            latencySeconds: 10, sensitivity: 0.5, falseAlarmRate: 1.0
        )
        XCTAssertEqual(alwaysFires.passLikelihoodRatio, .infinity)
        XCTAssertEqual(alwaysFires.passEvidencePerSecond, 0.0)
    }
}
