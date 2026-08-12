import Foundation

/// The class of feedback a verification signal produces.
///
/// The distinction that matters on iOS is not "test vs. not test" — it is how
/// legible the output is to the thing consuming it. A crash log is text. A
/// screenshot is not, unless something in the loop can actually read it.
public enum SignalLegibility: String, Sendable, Hashable, CaseIterable {
    /// Structured output an agent can parse and act on without a human.
    case machineReadable
    /// Text, but noisy — needs normalisation before it can be compared run to run.
    case noisyText
    /// Not text at all. A screenshot, a video, a rendered frame.
    case opaque
}

/// Where a signal sits in the iOS feedback stack.
public enum SignalKind: String, Sendable, Hashable, CaseIterable {
    case staticAnalysis
    case compile
    case unitTest
    case snapshotDiff
    case uiTest
    case simulatorLog
    case screenshot
    case humanReview
}

/// Errors raised when a signal is described with values that cannot represent
/// a real detector.
public enum SignalDefinitionError: Error, Equatable, CustomStringConvertible {
    case rateOutOfRange(field: String, value: Double)
    case nonPositiveLatency(Double)

    public var description: String {
        switch self {
        case let .rateOutOfRange(field, value):
            return "\(field) must be in 0.0...1.0, got \(value)"
        case let .nonPositiveLatency(value):
            return "latencySeconds must be > 0, got \(value)"
        }
    }
}

/// One rung of a verification ladder, described the way a detector actually
/// behaves rather than the way its README describes it.
///
/// `sensitivity` is `P(signal reports failure | the change really is defective)`.
/// `falseAlarmRate` is `P(signal reports failure | the change is fine)` — the
/// flakiness rate, measured on unchanged code.
///
/// Both numbers are needed. A signal described only by "it passes 95% of the
/// time" cannot be reasoned about at all, because that sentence does not say
/// what it passes *on*.
public struct VerificationSignal: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: SignalKind
    public let legibility: SignalLegibility
    /// Wall-clock cost of running this signal once, in seconds.
    public let latencySeconds: Double
    public let sensitivity: Double
    public let falseAlarmRate: Double

    public init(
        id: String,
        kind: SignalKind,
        legibility: SignalLegibility,
        latencySeconds: Double,
        sensitivity: Double,
        falseAlarmRate: Double
    ) throws {
        guard latencySeconds > 0 else {
            throw SignalDefinitionError.nonPositiveLatency(latencySeconds)
        }
        guard (0.0...1.0).contains(sensitivity) else {
            throw SignalDefinitionError.rateOutOfRange(field: "sensitivity", value: sensitivity)
        }
        guard (0.0...1.0).contains(falseAlarmRate) else {
            throw SignalDefinitionError.rateOutOfRange(field: "falseAlarmRate", value: falseAlarmRate)
        }
        self.id = id
        self.kind = kind
        self.legibility = legibility
        self.latencySeconds = latencySeconds
        self.sensitivity = sensitivity
        self.falseAlarmRate = falseAlarmRate
    }

    /// A signal only carries information if it is more likely to fire on a real
    /// defect than on a clean change.
    ///
    /// When `sensitivity == falseAlarmRate` the signal is a coin flip: its pass
    /// and its failure both leave belief exactly where they found it. It still
    /// costs `latencySeconds` to run.
    public var isInformative: Bool {
        sensitivity > falseAlarmRate
    }

    /// Likelihood ratio contributed by a *pass*: `P(pass | defect) / P(pass | clean)`.
    ///
    /// Values below 1 push belief away from "defective". Exactly 1 means the
    /// pass told you nothing.
    public var passLikelihoodRatio: Double {
        let numerator = 1.0 - sensitivity
        let denominator = 1.0 - falseAlarmRate
        guard denominator > 0 else { return Double.infinity }
        return numerator / denominator
    }

    /// Likelihood ratio contributed by a *failure*: `P(fail | defect) / P(fail | clean)`.
    public var failLikelihoodRatio: Double {
        guard falseAlarmRate > 0 else {
            return sensitivity > 0 ? Double.infinity : 1.0
        }
        return sensitivity / falseAlarmRate
    }

    /// How much "the change is clean" evidence a pass buys, per second of wall clock.
    ///
    /// Measured in bans (base-10 log units, also called hartleys) per second.
    /// This is the number a ladder should actually be sorted on — not latency,
    /// and not the subjective confidence anyone has in the suite.
    public var passEvidencePerSecond: Double {
        let ratio = passLikelihoodRatio
        guard ratio > 0, ratio.isFinite else { return 0 }
        return -log10(ratio) / latencySeconds
    }
}

/// What a signal reported on one run.
public enum SignalOutcome: Sendable, Hashable {
    case passed
    /// Reported a problem, carrying whatever output the loop gets to read.
    case failed(evidence: String)
    /// Ran, but could not reach a conclusion — simulator never booted, device
    /// dropped off, harness timed out. Distinct from a pass in every way that
    /// matters, and routinely collapsed into one in practice.
    case inconclusive(reason: String)

    public var isPass: Bool {
        if case .passed = self { return true }
        return false
    }
}

/// A signal paired with what it reported.
public struct SignalReading: Sendable, Hashable {
    public let signal: VerificationSignal
    public let outcome: SignalOutcome

    public init(signal: VerificationSignal, outcome: SignalOutcome) {
        self.signal = signal
        self.outcome = outcome
    }

    /// The multiplier this reading applies to the odds that the change is defective.
    ///
    /// An inconclusive run contributes exactly `1.0`. It cost wall clock and
    /// bought nothing — which is the honest accounting, and not what a green
    /// dashboard shows.
    public var likelihoodRatio: Double {
        switch outcome {
        case .passed:
            return signal.passLikelihoodRatio
        case .failed:
            return signal.failLikelihoodRatio
        case .inconclusive:
            return 1.0
        }
    }
}
