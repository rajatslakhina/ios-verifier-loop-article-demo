# VerifierLoopKit

A small Swift library that answers one question an iOS agent loop cannot currently answer: **when the run is green, what is that actually worth?**

Loop engineering advice — trigger, topology, verifier, stop rules, spend cap, sign-off gate — was written against stacks where the verifier is a fast, textual, deterministic test run. iOS is not that stack. Its feedback is a 90-second incremental build, a simulator boot, a flaky UI test, and a screenshot that a text-only model cannot read. This library treats the verifier as the designed component it should be, and prices every rung of it.

Article: **(added after publish)**

---

## The result it produces

Two ladders. Same prior (35% of agent-authored diffs arrive defective), same bar (close under 5% residual risk).

| Ladder | Rungs | Wall clock | Residual risk when fully green | Verdict |
|---|---|---|---|---|
| Legacy | lint → build → XCUITest smoke → simulator screenshot | **380s** | **16.6%** | Parks. Cannot reach the bar. |
| Engineered | lint → build → unit suite → snapshot diff | **128s** | **3.8%** | Closes. |

Three times less wall clock, four times less residual risk, and only one of them is ever allowed to land a change unattended.

The screenshot rung is the sharp edge. Its sensitivity equals its false-alarm rate, so its pass contributes a likelihood ratio of **exactly 1.0** — it moves belief by nothing at all while costing 95 seconds, a quarter of the legacy ladder's runtime. `VerifierLadder.theatreSeconds` prices that directly.

## The two ideas worth stealing

**1. A pass and a failure are not symmetric, and neither is worth the same across rungs.**
Each signal is described by two numbers a team can actually measure: `sensitivity` (fires when the change really is broken) and `falseAlarmRate` (fires on unchanged code). Everything else — evidence per second, ladder ordering, whether the ladder can clear its own bar at all — falls out of those two.

```swift
let shot = try IOSSignalCatalog.blindScreenshot()
shot.isInformative          // false
shot.passLikelihoodRatio    // 1.0 — exactly. A green that means nothing.
shot.passEvidencePerSecond  // 0.0
```

**2. Authority and evidence are different axes, and the gate is checked first.**
`LoopController.decide` resolves the irreversibility gate before a single signal runs — deliberately, so that a green ladder is never available as an argument for waving a `project.pbxproj` or signing-config rewrite through.

```swift
let change = ProposedChange(id: "agent-patch", touchedClasses: [.sourceCode, .projectFile])
let result = LoopController(policy: .standard, ladder: engineered)
    .run(change: change, outcomes: [:])   // every rung green

// .escalate — and result.ledger.elapsedSeconds == 0.
// The ladder never ran, because its answer was never relevant.
```

Same code, same green, one extra touched file, opposite verdict.

## What's in it

- `VerificationSignal` — a rung, described by latency, legibility and its two detection rates. Rejects rates outside `0...1` and non-positive latency at construction.
- `EvidenceLedger` — Bayesian tally in odds space, with `residualRisk`, `evidenceDecibans`, and `theatreSeconds`.
- `VerifierLadder` / `LadderAudit` — ordering by evidence-per-second, theatre detection, `riskFloor`, and the minimal green prefix that clears the bar.
- `IrreversibilityGate` / `ChangeClass` — which change classes a build-and-test ladder is structurally incapable of observing.
- `FailureFingerprint` — normalises absolute paths, simulator UDIDs, timestamps and pointer addresses so the same failure twice reads as *the same failure*, not as progress.
- `LoopController` — `close` / `runNext` / `rework` / `park` / `escalate`, ordered so that every free check runs before every check that authorises spend.
- `VerifierLoopUI` — a thin SwiftUI shell. Every number it renders comes from the tested core.

## Running it

```
git clone https://github.com/rajatslakhina/ios-verifier-loop-article-demo.git
cd ios-verifier-loop-article-demo
open Demo.xcodeproj      # pick any iOS Simulator, then Build & Run
```

One repo, no second checkout: `Demo.xcodeproj` consumes the library through a local Swift package reference (`relativePath = .`) pointed at this same directory.

Library and tests on their own:

```
swift build
swift test
```

## Verification status

Stated plainly, because a demo that overclaims its own verification would be an unusually poor advertisement for a library about verification.

- ✅ **`swift build` — passes.** Swift 6.0.3, Linux aarch64. Both library targets compile clean.
- ✅ **`swift test` — 62 tests, 0 failures.** Every number in the table above is asserted by a test, not typed by hand: the 380s/128s wall clocks, the 16.6%/3.8% risk floors, the exactly-1.0 screenshot ratio, the gate firing at zero elapsed seconds.
- ✅ **`Demo.xcodeproj/project.pbxproj` structurally audited** — braces 32/32, parens 24/24, 22 objects defined, zero dangling references. A shared `Demo.xcscheme` is committed so the scheme is selectable on a fresh clone.
- ✅ **No `.executableTarget`.** `Package.swift` declares library and test targets only; the runnable app lives exclusively in `Demo.xcodeproj`.
- ❌ **NOT run on the iOS Simulator, and there are no screenshots in this repo.** The build was produced in an unattended scheduled run with no macOS shell (no `xcodebuild`, no `simctl`) and no way to obtain interactive Xcode access. `VerifierLoopUI`'s body is guarded by `#if canImport(SwiftUI)`, so the Linux build compiles it to an empty module — **the SwiftUI code in this repo has been reviewed by hand but not compiled.** If you clone it and the demo view does not build, that is the gap, and a pull request is welcome.

## Licence

MIT.
