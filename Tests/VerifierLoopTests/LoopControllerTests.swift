import XCTest
@testable import VerifierLoop

final class LoopControllerTests: XCTestCase {

    private let sourceOnly = ProposedChange(id: "p1", touchedClasses: [.sourceCode, .testCode])

    private func controller(_ ladder: VerifierLadder, policy: LoopPolicy = .standard) -> LoopController {
        LoopController(policy: policy, ladder: ladder)
    }

    // MARK: - The two headline runs

    func testEngineeredLadderClosesAt128SecondsAndUnder4Percent() throws {
        let result = controller(try IOSSignalCatalog.engineeredLadder())
            .run(change: sourceOnly, outcomes: [:])
        guard case let .close(risk, spent) = result.verdict else {
            return XCTFail("expected close, got \(result.verdict)")
        }
        XCTAssertEqual(spent, 128)
        XCTAssertEqual(risk, 0.0378, accuracy: 0.0001)
        XCTAssertEqual(result.ledger.readings.count, 4)
    }

    /// The legacy ladder's honest answer is available before it runs. The
    /// controller refuses to spend 380 seconds reaching a verdict it can
    /// already prove it will not reach.
    func testLegacyLadderParksAtSecondZeroWithoutSpendingAnything() throws {
        let result = controller(try IOSSignalCatalog.legacyLadder())
            .run(change: sourceOnly, outcomes: [:])
        guard case let .park(.unreachableThreshold(best, threshold)) = result.verdict else {
            return XCTFail("expected unreachableThreshold, got \(result.verdict)")
        }
        XCTAssertEqual(best, 0.1664, accuracy: 0.0001)
        XCTAssertEqual(threshold, 0.05)
        XCTAssertEqual(result.ledger.elapsedSeconds, 0, "nothing should have been spent")
        XCTAssertTrue(result.ledger.readings.isEmpty)
    }

    // MARK: - Authority is not evidence

    /// Identical all-green evidence, one extra touched file, opposite verdict.
    func testProjectFileRewriteEscalatesDespiteAPerfectLadder() throws {
        let change = ProposedChange(id: "p2", touchedClasses: [.sourceCode, .projectFile])
        let result = controller(try IOSSignalCatalog.engineeredLadder())
            .run(change: change, outcomes: [:])
        guard case let .escalate(requirement) = result.verdict else {
            return XCTFail("expected escalate, got \(result.verdict)")
        }
        XCTAssertEqual(requirement.blockedBy, [.projectFile])
        XCTAssertEqual(result.ledger.elapsedSeconds, 0, "the gate must run before the ladder")
    }

    func testGateListsEveryBlockingClassInStableOrder() throws {
        let change = ProposedChange(
            id: "p3",
            touchedClasses: [.signingConfig, .sourceCode, .entitlements, .buildScript]
        )
        guard let requirement = IrreversibilityGate.iOSDefault.evaluate(change) else {
            return XCTFail("expected the gate to fire")
        }
        XCTAssertEqual(requirement.blockedBy, [.buildScript, .entitlements, .signingConfig])
        XCTAssertTrue(requirement.rationale.contains("signingConfig"))
    }

    func testSourceOnlyChangeDoesNotTripTheGate() {
        XCTAssertNil(IrreversibilityGate.iOSDefault.evaluate(sourceOnly))
    }

    func testUnobservableClassesAreExactlyTheGatedOnes() {
        let everything = ProposedChange(id: "p4", touchedClasses: Set(ChangeClass.allCases))
        XCTAssertEqual(everything.unobservableClasses, IrreversibilityGate.iOSDefault.humanRequiredFor)
    }

    // MARK: - Failure handling

    func testFirstRealFailureHandsBackRatherThanRunningTheRestOfTheLadder() throws {
        let result = controller(try IOSSignalCatalog.engineeredLadder()).run(
            change: sourceOnly,
            outcomes: ["swift-build": .failed(evidence: "Cart.swift:14 cannot convert value")]
        )
        guard case let .rework(fingerprint) = result.verdict else {
            return XCTFail("expected rework, got \(result.verdict)")
        }
        XCTAssertEqual(fingerprint.signalID, "swift-build")
        XCTAssertEqual(result.ledger.readings.count, 2, "should stop right after the failing rung")
        XCTAssertEqual(result.ledger.elapsedSeconds, 45)
    }

    func testTwoIdenticalFailuresParkTheLoopEvenAcrossDifferentCheckouts() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        let ladder = try IOSSignalCatalog.engineeredLadder()
        var ledger = EvidenceLedger(prior: LoopPolicy.standard.prior)
        ledger.record(SignalReading(
            signal: unit,
            outcome: .failed(evidence: "/Users/rajat/App/CartTests.swift:14 at 09:00:01")
        ))
        ledger.record(SignalReading(
            signal: unit,
            outcome: .failed(evidence: "/Users/ci/work/CartTests.swift:14 at 22:41:57")
        ))
        let verdict = controller(ladder).decide(change: sourceOnly, ledger: ledger, attempt: 1)
        guard case let .park(.noProgress(_, repeats)) = verdict else {
            return XCTFail("expected noProgress, got \(verdict)")
        }
        XCTAssertEqual(repeats, 2)
    }

    func testTwoDifferentFailuresAreProgressNotAStall() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        let ladder = try IOSSignalCatalog.engineeredLadder()
        var ledger = EvidenceLedger(prior: LoopPolicy.standard.prior)
        ledger.record(SignalReading(signal: unit, outcome: .failed(evidence: "CartTests.swift:14")))
        ledger.record(SignalReading(signal: unit, outcome: .failed(evidence: "CheckoutTests.swift:81")))
        let verdict = controller(ladder).decide(change: sourceOnly, ledger: ledger, attempt: 1)
        guard case .rework = verdict else {
            return XCTFail("expected rework, got \(verdict)")
        }
    }

    // MARK: - Budgets

    func testAttemptCeilingParksTheLoop() throws {
        let verdict = controller(try IOSSignalCatalog.engineeredLadder()).decide(
            change: sourceOnly,
            ledger: EvidenceLedger(prior: 0.35),
            attempt: 5
        )
        guard case let .park(.attemptsExhausted(attempts, limit)) = verdict else {
            return XCTFail("expected attemptsExhausted, got \(verdict)")
        }
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(limit, 4)
    }

    func testWallClockBudgetParksTheLoopOnceSpent() throws {
        let policy = LoopPolicy(
            prior: 0.35, closeThreshold: 0.05, wallClockBudgetSeconds: 40,
            maxAttempts: 4, noProgressLimit: 2, gate: .iOSDefault
        )
        let generous = try VerifierLadder(
            name: "generous",
            signals: [IOSSignalCatalog.lint(), IOSSignalCatalog.build(), IOSSignalCatalog.unitSuite(),
                      IOSSignalCatalog.snapshotDiff(), IOSSignalCatalog.uiSmoke()]
        )
        var ledger = EvidenceLedger(prior: policy.prior)
        ledger.record(SignalReading(signal: try IOSSignalCatalog.build(), outcome: .passed))
        let verdict = LoopController(policy: policy, ladder: generous)
            .decide(change: sourceOnly, ledger: ledger, attempt: 1)
        guard case let .park(.budgetExhausted(spent, budget)) = verdict else {
            return XCTFail("expected budgetExhausted, got \(verdict)")
        }
        XCTAssertEqual(spent, 42)
        XCTAssertEqual(budget, 40)
    }

    func testAnEmptyLadderParksInsteadOfClaimingSuccess() {
        let verdict = controller(VerifierLadder(name: "empty", signals: []))
            .decide(change: sourceOnly, ledger: EvidenceLedger(prior: 0.35), attempt: 1)
        guard case .park(.unreachableThreshold) = verdict else {
            return XCTFail("expected unreachableThreshold, got \(verdict)")
        }
    }

    /// `run` must terminate even if a ladder is fed a repeated signal id.
    func testRunTerminatesOnADuplicatedRung() throws {
        let unit = try IOSSignalCatalog.unitSuite()
        let ladder = VerifierLadder(name: "dupes", signals: [unit, unit, unit])
        let result = controller(ladder).run(change: sourceOnly, outcomes: [:])
        XCTAssertLessThanOrEqual(result.ledger.readings.count, ladder.signals.count + 1)
        guard case .park = result.verdict else {
            return XCTFail("expected park, got \(result.verdict)")
        }
    }
}
