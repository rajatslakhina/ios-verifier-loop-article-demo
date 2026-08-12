import Foundation

/// What a proposed change touches.
///
/// A build-and-test ladder observes exactly one of these well. The rest it
/// cannot see at all — which is why a green ladder is not an argument for
/// letting a change through.
public enum ChangeClass: String, Sendable, Hashable, CaseIterable {
    case sourceCode
    case testCode
    case resources
    case projectFile
    case dependencyPin
    case buildScript
    case signingConfig
    case entitlements

    /// Whether a passing build/test ladder is capable of observing damage to
    /// this class of change at all.
    ///
    /// A rewritten signing config compiles. A reordered `project.pbxproj`
    /// compiles. A silently widened dependency range compiles. The ladder is
    /// not being lenient — it is blind.
    public var observableByBuildAndTest: Bool {
        switch self {
        case .sourceCode, .testCode, .resources:
            return true
        case .projectFile, .dependencyPin, .buildScript, .signingConfig, .entitlements:
            return false
        }
    }
}

/// A change the loop is being asked to sign off on.
public struct ProposedChange: Sendable, Hashable {
    public let id: String
    public let touchedClasses: Set<ChangeClass>

    public init(id: String, touchedClasses: Set<ChangeClass>) {
        self.id = id
        self.touchedClasses = touchedClasses
    }

    /// Classes this change touches that no amount of green can speak to.
    public var unobservableClasses: Set<ChangeClass> {
        touchedClasses.filter { !$0.observableByBuildAndTest }
    }
}

/// The authority half of the decision, kept deliberately separate from the
/// evidence half.
///
/// Evidence answers "do I believe this is correct?". The gate answers "am I
/// allowed to land it unattended?". Collapsing the two is how a green pipeline
/// ends up arguing its way past a signing-config rewrite.
public struct IrreversibilityGate: Sendable, Equatable {
    /// Change classes that always require a human, regardless of the ladder.
    public let humanRequiredFor: Set<ChangeClass>

    public init(humanRequiredFor: Set<ChangeClass>) {
        self.humanRequiredFor = humanRequiredFor
    }

    /// The default iOS posture: everything the build/test ladder structurally
    /// cannot observe needs a human.
    public static let iOSDefault = IrreversibilityGate(
        humanRequiredFor: [.projectFile, .dependencyPin, .buildScript, .signingConfig, .entitlements]
    )

    public struct Requirement: Sendable, Equatable {
        public let blockedBy: [ChangeClass]
        public let rationale: String
    }

    /// Evaluated against the change alone. No evidence is passed in, on purpose.
    public func evaluate(_ change: ProposedChange) -> Requirement? {
        let blocked = change.touchedClasses
            .intersection(humanRequiredFor)
            .sorted { $0.rawValue < $1.rawValue }
        guard !blocked.isEmpty else { return nil }
        let names = blocked.map(\.rawValue).joined(separator: ", ")
        return Requirement(
            blockedBy: blocked,
            rationale: "Touches \(names) — outside what the build/test ladder can observe."
        )
    }
}

/// A failure, reduced to something comparable across runs.
///
/// Two runs of the same broken change on iOS almost never produce byte-identical
/// output: absolute paths differ per checkout, simulator UDIDs are regenerated,
/// timestamps move, and pointer addresses are randomised. Comparing raw strings
/// makes every failure look new, and a loop that thinks every failure is new
/// will happily retry the same one until its budget is gone.
public struct FailureFingerprint: Sendable, Hashable, CustomStringConvertible {
    public let signalID: String
    public let normalizedEvidence: String

    public init(signalID: String, rawEvidence: String) {
        self.signalID = signalID
        self.normalizedEvidence = FailureFingerprint.normalize(rawEvidence)
    }

    public var description: String { "\(signalID)#\(normalizedEvidence)" }

    /// Collapses the parts of iOS tool output that change every run.
    ///
    /// Hand-rolled rather than regex-driven so the behaviour is identical on
    /// every platform this runs on, and so each rule is individually testable.
    public static func normalize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var token = ""

        func flush() {
            guard !token.isEmpty else { return }
            out += classify(token)
            token = ""
        }

        for character in raw {
            if character.isWhitespace {
                flush()
                if !out.hasSuffix(" ") { out += " " }
            } else {
                token.append(character)
            }
        }
        flush()

        while out.hasSuffix(" ") { out.removeLast() }
        while out.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    private static func classify(_ token: String) -> String {
        if token.hasPrefix("/") || token.contains("/Users/") || token.contains("/DerivedData/") {
            // Absolute paths differ per checkout and per CI runner. Keep the
            // last component so the file identity survives.
            let tail = token.split(separator: "/").last.map(String.init) ?? "PATH"
            return "<path>/" + tail
        }
        if token.hasPrefix("0x") {
            return "<addr>"
        }
        if isUDIDShaped(token) {
            return "<udid>"
        }
        if isTimestampShaped(token) {
            return "<time>"
        }
        if isPurelyNumeric(token), token.count >= 5 {
            return "<num>"
        }
        return token
    }

    private static func isPurelyNumeric(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    /// `8-4-4-4-12` hex, the shape `simctl` hands back for every simulator.
    private static func isUDIDShaped(_ token: String) -> Bool {
        let groups = token.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5 else { return false }
        let expected = [8, 4, 4, 4, 12]
        for index in 0..<5 where groups[index].count != expected[index] {
            return false
        }
        return groups.allSatisfy { group in
            group.allSatisfy(\.isHexDigit)
        }
    }

    /// `HH:MM:SS`, optionally with a fractional part.
    private static func isTimestampShaped(_ token: String) -> Bool {
        let head = token.split(separator: ".", maxSplits: 1).first.map(String.init) ?? token
        let parts = head.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            part.count == 2 && part.allSatisfy(\.isNumber)
        }
    }
}

/// Why a loop stopped without a verdict.
public enum ParkReason: Sendable, Equatable, CustomStringConvertible {
    case budgetExhausted(spentSeconds: Double, budgetSeconds: Double)
    case attemptsExhausted(attempts: Int, limit: Int)
    case noProgress(fingerprint: FailureFingerprint, repeats: Int)
    case unreachableThreshold(bestAchievable: Double, threshold: Double)

    public var description: String {
        switch self {
        case let .budgetExhausted(spent, budget):
            return "Budget exhausted: spent \(Int(spent))s of \(Int(budget))s."
        case let .attemptsExhausted(attempts, limit):
            return "Attempts exhausted: \(attempts) of \(limit)."
        case let .noProgress(fingerprint, repeats):
            return "No progress: \(fingerprint.signalID) failed identically \(repeats)x."
        case let .unreachableThreshold(best, threshold):
            let bestPct = String(format: "%.1f", best * 100)
            let thresholdPct = String(format: "%.1f", threshold * 100)
            return "Ladder cannot reach \(thresholdPct)% even fully green — floor is \(bestPct)%."
        }
    }
}
