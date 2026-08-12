import Foundation

/// Everything the loop is allowed to spend, and the bar it has to clear.
public struct LoopPolicy: Sendable, Equatable {
    /// `P(defective)` for a change coming out of this loop before anything runs.
    public let prior: Double
    /// Residual risk the loop must get under before it may close.
    public let closeThreshold: Double
    public let wallClockBudgetSeconds: Double
    public let maxAttempts: Int
    /// How many identical failures in a row count as "stuck".
    public let noProgressLimit: Int
    public let gate: IrreversibilityGate

    public init(
        prior: Double,
        closeThreshold: Double,
        wallClockBudgetSeconds: Double,
        maxAttempts: Int,
        noProgressLimit: Int,
        gate: IrreversibilityGate
    ) {
        self.prior = prior
        self.closeThreshold = closeThreshold
        self.wallClockBudgetSeconds = wallClockBudgetSeconds
        self.maxAttempts = maxAttempts
        self.noProgressLimit = noProgressLimit
        self.gate = gate
    }

    /// A deliberately unglamorous default: agent-authored diffs are wrong about
    /// a third of the time before anything checks them, and a 5% residual is
    /// the most a loop should land unattended.
    public static let standard = LoopPolicy(
        prior: 0.35,
        closeThreshold: 0.05,
        wallClockBudgetSeconds: 600,
        maxAttempts: 4,
        noProgressLimit: 2,
        gate: .iOSDefault
    )
}

/// What the loop decided.
public enum LoopVerdict: Sendable, Equatable {
    /// Enough trustworthy evidence accumulated. Land it.
    case close(residualRisk: Double, spentSeconds: Double)
    /// Keep going — run this signal next.
    case runNext(VerificationSignal)
    /// A signal reported a real problem. Stop verifying and hand it back; there
    /// is nothing further down the ladder worth paying for yet.
    case rework(fingerprint: FailureFingerprint)
    /// Stop, without a conclusion, for a reason worth reading.
    case park(ParkReason)
    /// A human has to look, and no amount of green changes that.
    case escalate(IrreversibilityGate.Requirement)
}

/// Drives one verification loop over one proposed change.
///
/// The ordering rule is one line: **every check that costs nothing to evaluate
/// runs before every check that authorises spend.** The gate, the attempt
/// count, the failure fingerprints and the reachability floor are all free, and
/// all four can end the loop. Running them after the ladder is how a pipeline
/// spends six minutes arriving at an answer it already had.
public struct LoopController: Sendable {
    public let policy: LoopPolicy
    public let ladder: VerifierLadder

    public init(policy: LoopPolicy, ladder: VerifierLadder) {
        self.policy = policy
        self.ladder = ladder
    }

    /// Decide what the loop should do next given everything it knows so far.
    ///
    /// - Parameters:
    ///   - change: what is being proposed.
    ///   - ledger: readings gathered so far, in the order they were gathered.
    ///   - attempt: which iteration of the fix-and-recheck loop this is, 1-based.
    public func decide(
        change: ProposedChange,
        ledger: EvidenceLedger,
        attempt: Int
    ) -> LoopVerdict {
        // 1. Authority, before anything is spent. Checked first specifically so
        //    that a green ladder is never available as an argument for waving a
        //    signing-config rewrite through.
        if let requirement = policy.gate.evaluate(change) {
            return .escalate(requirement)
        }

        // 2. Attempt ceiling. Free to check, and it ends the loop outright.
        if attempt > policy.maxAttempts {
            return .park(.attemptsExhausted(attempts: attempt, limit: policy.maxAttempts))
        }

        // 3. Stuck beats slow. An identical failure repeated is a loop that has
        //    stopped learning, and more attempts will not change that.
        if let stuck = repeatedFailure(in: ledger) {
            return .park(.noProgress(fingerprint: stuck.fingerprint, repeats: stuck.count))
        }

        // 4. Something failed and it is not a repeat: hand it back. Running the
        //    rest of the ladder against a change already known to be broken buys
        //    nothing but wall clock.
        if let latest = latestFailure(in: ledger) {
            return .rework(fingerprint: latest)
        }

        // 5. Can this ladder even get where it needs to go? A loop that would
        //    still be over threshold on a perfect run should say so at second
        //    zero, not after six minutes of green.
        let remaining = remainingSignals(after: ledger)
        let floor = ledger.bestAchievableRisk(addingPassesFor: remaining)
        if floor > policy.closeThreshold {
            return .park(.unreachableThreshold(bestAchievable: floor, threshold: policy.closeThreshold))
        }

        // 6. Already under threshold? Then every remaining signal is confirmation
        //    of a conclusion already reached, and confirmation is not free.
        if ledger.residualRisk <= policy.closeThreshold {
            return .close(residualRisk: ledger.residualRisk, spentSeconds: ledger.elapsedSeconds)
        }

        // 7. Wall clock. Last, because it is the only check that needed money
        //    spent before it could say anything.
        if ledger.elapsedSeconds >= policy.wallClockBudgetSeconds {
            return .park(.budgetExhausted(
                spentSeconds: ledger.elapsedSeconds,
                budgetSeconds: policy.wallClockBudgetSeconds
            ))
        }

        // 8. Otherwise run the next signal that has not been run yet.
        guard let next = remaining.first else {
            return .park(.unreachableThreshold(
                bestAchievable: ledger.residualRisk,
                threshold: policy.closeThreshold
            ))
        }
        return .runNext(next)
    }

    /// Runs the ladder start to finish against a fixed set of outcomes.
    ///
    /// Used by the demo and the tests: a real loop would call `decide` between
    /// each signal, which is exactly what this does.
    public func run(
        change: ProposedChange,
        outcomes: [String: SignalOutcome],
        attempt: Int = 1
    ) -> (verdict: LoopVerdict, ledger: EvidenceLedger) {
        var ledger = EvidenceLedger(prior: policy.prior)
        var verdict = decide(change: change, ledger: ledger, attempt: attempt)
        var guardCounter = 0
        let hardCeiling = ladder.signals.count + 1

        while case let .runNext(signal) = verdict {
            guardCounter += 1
            if guardCounter > hardCeiling { break }
            let outcome = outcomes[signal.id] ?? .passed
            ledger.record(SignalReading(signal: signal, outcome: outcome))
            verdict = decide(change: change, ledger: ledger, attempt: attempt)
        }
        return (verdict, ledger)
    }

    private func remainingSignals(after ledger: EvidenceLedger) -> [VerificationSignal] {
        let used = Set(ledger.readings.map(\.signal.id))
        return ladder.signals.filter { !used.contains($0.id) }
    }

    private func latestFailure(in ledger: EvidenceLedger) -> FailureFingerprint? {
        for reading in ledger.readings.reversed() {
            guard case let .failed(evidence) = reading.outcome else { continue }
            return FailureFingerprint(signalID: reading.signal.id, rawEvidence: evidence)
        }
        return nil
    }

    private func repeatedFailure(in ledger: EvidenceLedger) -> (fingerprint: FailureFingerprint, count: Int)? {
        var counts: [FailureFingerprint: Int] = [:]
        for reading in ledger.readings {
            guard case let .failed(evidence) = reading.outcome else { continue }
            let fingerprint = FailureFingerprint(signalID: reading.signal.id, rawEvidence: evidence)
            let next = (counts[fingerprint] ?? 0) + 1
            counts[fingerprint] = next
            if next >= policy.noProgressLimit {
                return (fingerprint, next)
            }
        }
        return nil
    }
}
