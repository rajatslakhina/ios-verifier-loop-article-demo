import Foundation

/// The whole comparison, computed once, with no SwiftUI anywhere near it.
///
/// The rendering layer is a thin shell over this type on purpose: everything
/// worth being wrong about is here, where tests can reach it.
public struct LoopDemo: Sendable {
    public let policy: LoopPolicy
    public let legacy: VerifierLadder
    public let engineered: VerifierLadder
    public let rankedSignals: [VerificationSignal]

    public init(policy: LoopPolicy = .standard) throws {
        self.policy = policy
        self.legacy = try IOSSignalCatalog.legacyLadder()
        self.engineered = try IOSSignalCatalog.engineeredLadder()
        self.rankedSignals = try IOSSignalCatalog.all().sorted { lhs, rhs in
            if lhs.passEvidencePerSecond != rhs.passEvidencePerSecond {
                return lhs.passEvidencePerSecond > rhs.passEvidencePerSecond
            }
            return lhs.id < rhs.id
        }
    }

    public var legacyAudit: LadderAudit {
        LadderAudit(ladder: legacy, prior: policy.prior, threshold: policy.closeThreshold)
    }

    public var engineeredAudit: LadderAudit {
        LadderAudit(ladder: engineered, prior: policy.prior, threshold: policy.closeThreshold)
    }

    /// The headline: an all-green run of each ladder, and what it is worth.
    public func allGreenOutcome(for ladder: VerifierLadder) -> (verdict: LoopVerdict, ledger: EvidenceLedger) {
        let controller = LoopController(policy: policy, ladder: ladder)
        let change = ProposedChange(id: "agent-patch-1", touchedClasses: [.sourceCode, .testCode])
        return controller.run(change: change, outcomes: [:])
    }

    /// The same all-green engineered run, on a change that also rewrites the
    /// project file. Same evidence, different answer.
    ///
    /// Returns the ledger too, because the interesting part is not just the
    /// verdict — it is that `elapsedSeconds` is still zero when it arrives.
    public func gatedOutcome() -> (verdict: LoopVerdict, ledger: EvidenceLedger) {
        let controller = LoopController(policy: policy, ladder: engineered)
        let change = ProposedChange(
            id: "agent-patch-2",
            touchedClasses: [.sourceCode, .projectFile]
        )
        return controller.run(change: change, outcomes: [:])
    }

    /// Residual risk if `dropped` were removed from the engineered ladder and
    /// everything else still passed.
    ///
    /// Answers the only honest version of "is this rung load-bearing?".
    public func engineeredRiskWithout(_ dropped: VerificationSignal) -> Double {
        VerifierLadder(
            name: "engineered minus \(dropped.id)",
            signals: engineered.signals.filter { $0.id != dropped.id }
        ).riskFloor(prior: policy.prior)
    }

    /// How much worse the legacy ladder leaves you, as a multiple.
    public var residualRiskRatio: Double {
        let engineeredRisk = engineeredAudit.riskFloor
        guard engineeredRisk > 0 else { return .infinity }
        return legacyAudit.riskFloor / engineeredRisk
    }

    public var wallClockRatio: Double {
        let engineeredSeconds = engineered.totalLatencySeconds
        guard engineeredSeconds > 0 else { return .infinity }
        return legacy.totalLatencySeconds / engineeredSeconds
    }
}

/// Formatting helpers shared by the demo UI and the tests, kept here so the two
/// can never disagree about what a number means.
public enum LoopFormat {
    public static func percent(_ value: Double, places: Int = 1) -> String {
        String(format: "%.\(places)f%%", value * 100)
    }

    public static func seconds(_ value: Double) -> String {
        value < 60
            ? "\(Int(value.rounded()))s"
            : "\(Int(value) / 60)m \(Int(value) % 60)s"
    }

    public static func multiple(_ value: Double, places: Int = 1) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.\(places)f×", value)
    }
}
