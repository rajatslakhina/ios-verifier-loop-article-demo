import Foundation

/// An ordered set of signals a loop can spend wall clock on.
///
/// The ordering is the interesting part. Most iOS pipelines are ordered by
/// habit — lint, build, unit, UI, screenshot — which happens to be roughly
/// cheapest-first and is therefore *accidentally* defensible. It stops being
/// defensible the moment a slow signal carries more evidence than a fast one,
/// and nobody re-sorts because nobody wrote the evidence down.
public struct VerifierLadder: Sendable, Equatable {
    public let name: String
    public let signals: [VerificationSignal]

    public init(name: String, signals: [VerificationSignal]) {
        self.name = name
        self.signals = signals
    }

    public var totalLatencySeconds: Double {
        signals.reduce(0) { $0 + $1.latencySeconds }
    }

    /// Signals that cannot move the odds at all, no matter what they report.
    public var theatreSignals: [VerificationSignal] {
        signals.filter { !$0.isInformative }
    }

    /// Wall clock this ladder spends on signals that carry zero information.
    public var theatreSeconds: Double {
        theatreSignals.reduce(0) { $0 + $1.latencySeconds }
    }

    /// Re-sorted so the signal that buys the most belief per second runs first.
    ///
    /// Ties break on latency, then on `id`, so the ordering is stable across
    /// runs and a diff of the ladder is reviewable.
    public func orderedByEvidenceDensity() -> VerifierLadder {
        let sorted = signals.sorted { lhs, rhs in
            if lhs.passEvidencePerSecond != rhs.passEvidencePerSecond {
                return lhs.passEvidencePerSecond > rhs.passEvidencePerSecond
            }
            if lhs.latencySeconds != rhs.latencySeconds {
                return lhs.latencySeconds < rhs.latencySeconds
            }
            return lhs.id < rhs.id
        }
        return VerifierLadder(name: name, signals: sorted)
    }

    /// Drops every signal that carries no information, keeping order otherwise.
    public func withoutTheatre() -> VerifierLadder {
        VerifierLadder(name: name, signals: signals.filter(\.isInformative))
    }

    /// Lowest residual risk this ladder can reach from `prior` if every signal
    /// passes.
    public func riskFloor(prior: Double) -> Double {
        EvidenceLedger(prior: prior).bestAchievableRisk(addingPassesFor: signals)
    }

    /// Whether this ladder is capable of clearing `threshold` at all.
    public func canReach(threshold: Double, prior: Double) -> Bool {
        riskFloor(prior: prior) <= threshold
    }

    /// The shortest prefix of this ladder that clears `threshold` when every
    /// signal in it passes, or `nil` if no prefix does.
    ///
    /// Everything after that prefix is, on a green run, wall clock spent to
    /// confirm a conclusion already reached.
    public func minimalGreenPrefix(threshold: Double, prior: Double) -> [VerificationSignal]? {
        var ledger = EvidenceLedger(prior: prior)
        var prefix: [VerificationSignal] = []
        for signal in signals {
            ledger.record(SignalReading(signal: signal, outcome: .passed))
            prefix.append(signal)
            if ledger.residualRisk <= threshold {
                return prefix
            }
        }
        return nil
    }
}

/// A read-only report on a ladder, suitable for putting in front of someone who
/// has to decide whether to keep paying for it.
public struct LadderAudit: Sendable, Equatable {
    public let ladderName: String
    public let signalCount: Int
    public let totalLatencySeconds: Double
    public let theatreSeconds: Double
    public let riskFloor: Double
    public let clearsThreshold: Bool
    public let minimalGreenPrefixIDs: [String]
    /// Wall clock of the shortest green prefix that clears the threshold.
    public let prefixSeconds: Double

    public init(ladder: VerifierLadder, prior: Double, threshold: Double) {
        let prefix = ladder.minimalGreenPrefix(threshold: threshold, prior: prior) ?? []
        self.ladderName = ladder.name
        self.signalCount = ladder.signals.count
        self.totalLatencySeconds = ladder.totalLatencySeconds
        self.theatreSeconds = ladder.theatreSeconds
        self.riskFloor = ladder.riskFloor(prior: prior)
        self.clearsThreshold = ladder.canReach(threshold: threshold, prior: prior)
        self.minimalGreenPrefixIDs = prefix.map(\.id)
        self.prefixSeconds = prefix.reduce(0) { $0 + $1.latencySeconds }
    }

    /// Wall clock a fully green run spends after the threshold is already met.
    public var wastedGreenSeconds: Double {
        guard clearsThreshold else { return 0 }
        return max(0, totalLatencySeconds - prefixSeconds)
    }
}
