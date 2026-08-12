import Foundation

/// A worked iOS verification stack, with the two numbers that decide everything
/// written down instead of assumed.
///
/// The rates below are illustrative and deliberately conservative-looking rather
/// than measured from any one team's CI. They are the shape of the argument, not
/// a benchmark. The point of the type is that your team's real numbers go here,
/// in a file that gets reviewed, instead of living as folklore about which suite
/// people trust.
public enum IOSSignalCatalog {

    /// `swiftlint` plus macro-expansion pre-flight. Cheap, and catches a narrow
    /// but real slice of agent output: wrong API shape, unexpanded macro, style
    /// violations the compiler tolerates.
    public static func lint() throws -> VerificationSignal {
        try VerificationSignal(
            id: "swiftlint+macro-preflight",
            kind: .staticAnalysis,
            legibility: .machineReadable,
            latencySeconds: 3,
            sensitivity: 0.15,
            falseAlarmRate: 0.02
        )
    }

    /// `swift build` against the package graph, not a full Xcode scheme.
    /// Almost never lies, and catches every defect that is a type error.
    public static func build() throws -> VerificationSignal {
        try VerificationSignal(
            id: "swift-build",
            kind: .compile,
            legibility: .machineReadable,
            latencySeconds: 42,
            sensitivity: 0.45,
            falseAlarmRate: 0.01
        )
    }

    /// The unit suite. The single most informative rung available on iOS, and
    /// routinely the one a legacy pipeline has least of.
    public static func unitSuite() throws -> VerificationSignal {
        try VerificationSignal(
            id: "unit-suite",
            kind: .unitTest,
            legibility: .machineReadable,
            latencySeconds: 28,
            sensitivity: 0.70,
            falseAlarmRate: 0.03
        )
    }

    /// Snapshot diffing. The trick that makes a rendered view legible to a
    /// text-only loop: the assertion is not the image, it is the diff verdict.
    public static func snapshotDiff() throws -> VerificationSignal {
        try VerificationSignal(
            id: "snapshot-diff",
            kind: .snapshotDiff,
            legibility: .machineReadable,
            latencySeconds: 55,
            sensitivity: 0.55,
            falseAlarmRate: 0.08
        )
    }

    /// An XCUITest smoke pack. Four minutes, and it cries wolf on roughly a
    /// fifth of clean runs.
    public static func uiSmoke() throws -> VerificationSignal {
        try VerificationSignal(
            id: "xcuitest-smoke",
            kind: .uiTest,
            legibility: .noisyText,
            latencySeconds: 240,
            sensitivity: 0.40,
            falseAlarmRate: 0.22
        )
    }

    /// A simulator screenshot, captured and handed to something that cannot see.
    ///
    /// `sensitivity == falseAlarmRate` is not a modelling shortcut. It is the
    /// claim: to a text-only consumer this rung fires on noise as often as it
    /// fires on damage, so its verdict is independent of whether the change is
    /// broken.
    public static func blindScreenshot() throws -> VerificationSignal {
        try VerificationSignal(
            id: "sim-screenshot",
            kind: .screenshot,
            legibility: .opaque,
            latencySeconds: 95,
            sensitivity: 0.02,
            falseAlarmRate: 0.02
        )
    }

    /// The ladder a lot of iOS pipelines actually have: lint, build, a UI smoke
    /// pack, and a screenshot nobody reads.
    public static func legacyLadder() throws -> VerifierLadder {
        try VerifierLadder(
            name: "Legacy ladder",
            signals: [lint(), build(), uiSmoke(), blindScreenshot()]
        )
    }

    /// The same budget, re-spent: the UI pack and the screenshot are replaced by
    /// a unit suite and a snapshot diff.
    public static func engineeredLadder() throws -> VerifierLadder {
        try VerifierLadder(
            name: "Engineered ladder",
            signals: [lint(), build(), unitSuite(), snapshotDiff()]
        )
    }

    /// Every signal defined above, for ranking and inspection.
    public static func all() throws -> [VerificationSignal] {
        try [lint(), build(), unitSuite(), snapshotDiff(), uiSmoke(), blindScreenshot()]
    }
}
