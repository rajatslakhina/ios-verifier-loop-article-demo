import Foundation

/// Running tally of what a loop actually knows about a proposed change.
///
/// The ledger starts at a prior — how often this loop's changes turn out to be
/// defective — and multiplies in one likelihood ratio per signal reading. It
/// exists so that "the run was green" can be converted into a number, because
/// "green" on its own is not a claim about anything.
public struct EvidenceLedger: Sendable, Equatable {
    /// `P(defective)` before any signal has run.
    public let prior: Double
    public private(set) var readings: [SignalReading]

    public init(prior: Double) {
        self.prior = min(max(prior, 0.0), 1.0)
        self.readings = []
    }

    public mutating func record(_ reading: SignalReading) {
        readings.append(reading)
    }

    public func recording(_ reading: SignalReading) -> EvidenceLedger {
        var copy = self
        copy.record(reading)
        return copy
    }

    /// Total wall clock burned to produce every reading in the ledger.
    public var elapsedSeconds: Double {
        readings.reduce(0) { $0 + $1.signal.latencySeconds }
    }

    /// Wall clock spent on readings that moved the odds by exactly nothing.
    ///
    /// This is the number worth putting on a slide. It is time the loop spent
    /// looking busy.
    public var theatreSeconds: Double {
        readings.reduce(0) { total, reading in
            reading.likelihoodRatio == 1.0 ? total + reading.signal.latencySeconds : total
        }
    }

    /// `P(defective)` after every recorded reading.
    ///
    /// Computed in odds space and converted back once, so a long ladder does
    /// not accumulate rounding drift from repeated probability round-trips.
    public var residualRisk: Double {
        guard prior > 0 else { return 0 }
        guard prior < 1 else { return 1 }
        var odds = prior / (1.0 - prior)
        for reading in readings {
            let ratio = reading.likelihoodRatio
            guard ratio.isFinite else { return 1.0 }
            odds *= ratio
        }
        guard odds.isFinite else { return 1.0 }
        return odds / (1.0 + odds)
    }

    /// How far the ladder actually moved belief, in bans (base-10 log units,
    /// also called hartleys — one ban is ten decibans).
    ///
    /// Positive means the evidence argued the change is clean.
    public var evidenceBans: Double {
        var total = 0.0
        for reading in readings {
            let ratio = reading.likelihoodRatio
            guard ratio > 0, ratio.isFinite else { continue }
            total += -log10(ratio)
        }
        return total
    }

    /// The floor this ladder can reach: residual risk if every remaining signal
    /// in `candidates` also passed.
    ///
    /// A loop that cannot get under its close threshold even on a perfect run
    /// is not slow. It is incapable, and it should say so before it spends the
    /// wall clock finding out.
    public func bestAchievableRisk(addingPassesFor candidates: [VerificationSignal]) -> Double {
        var projected = self
        for signal in candidates {
            projected.record(SignalReading(signal: signal, outcome: .passed))
        }
        return projected.residualRisk
    }
}
