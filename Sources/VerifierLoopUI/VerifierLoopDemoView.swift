#if canImport(SwiftUI)
import SwiftUI
import VerifierLoop

/// Deliberately thin. Every number on screen comes from `LoopDemo`, which lives
/// in the core module and is covered by tests — so there is nothing here that
/// can be quietly wrong in a way `swift test` would miss.
public struct VerifierLoopDemoView: View {
    private let demo: LoopDemo?
    @State private var touchesProjectFile = false

    public init() {
        self.demo = try? LoopDemo()
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let demo {
                    content(demo)
                } else {
                    ContentUnavailableView(
                        "Signal catalog failed validation",
                        systemImage: "exclamationmark.triangle",
                        description: Text("A signal was defined with a rate outside 0...1.")
                    )
                }
            }
            .navigationTitle("Verifier Loop")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func content(_ demo: LoopDemo) -> some View {
        List {
            Section {
                verdictRow(demo)
            } header: {
                Text("Verdict on an all-green run")
            } footer: {
                Text("Prior \(LoopFormat.percent(demo.policy.prior, places: 0)) · close under \(LoopFormat.percent(demo.policy.closeThreshold, places: 0))")
            }

            Section("Authority gate") {
                Toggle("Change also rewrites project.pbxproj", isOn: $touchesProjectFile)
                    .font(.subheadline)
                gateRow(demo)
            }

            Section("Ladders") {
                ladderRow(demo.legacy, audit: demo.legacyAudit)
                ladderRow(demo.engineered, audit: demo.engineeredAudit)
            }

            Section {
                ForEach(demo.rankedSignals) { signal in
                    signalRow(signal)
                }
            } header: {
                Text("Evidence bought per second")
            } footer: {
                Text("Sorted by how much belief a pass buys per second of wall clock. The bottom rung buys exactly none.")
            }
        }
    }

    // MARK: - Rows

    private func verdictRow(_ demo: LoopDemo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                metric(
                    title: "Legacy",
                    value: LoopFormat.percent(demo.legacyAudit.riskFloor),
                    caption: LoopFormat.seconds(demo.legacy.totalLatencySeconds) + " · over the bar",
                    tint: .red
                )
                Divider()
                metric(
                    title: "Engineered",
                    value: LoopFormat.percent(demo.engineeredAudit.riskFloor),
                    caption: LoopFormat.seconds(demo.engineered.totalLatencySeconds) + " · closes",
                    tint: .green
                )
            }
            Text("\(LoopFormat.multiple(demo.wallClockRatio)) the wall clock for \(LoopFormat.multiple(demo.residualRiskRatio)) the residual risk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func gateRow(_ demo: LoopDemo) -> some View {
        let verdict: LoopVerdict = touchesProjectFile
            ? demo.gatedOutcome()
            : demo.allGreenOutcome(for: demo.engineered).verdict
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: verdict))
                .foregroundStyle(tint(for: verdict))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(for: verdict)).font(.subheadline.weight(.semibold))
                Text(detail(for: verdict)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func ladderRow(_ ladder: VerifierLadder, audit: LadderAudit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ladder.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(LoopFormat.seconds(ladder.totalLatencySeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(ladder.signals.map(\.id).joined(separator: " → "))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                badge(
                    audit.clearsThreshold ? "clears \(LoopFormat.percent(0.05, places: 0))" : "floor \(LoopFormat.percent(audit.riskFloor))",
                    tint: audit.clearsThreshold ? .green : .red
                )
                if audit.theatreSeconds > 0 {
                    badge("\(LoopFormat.seconds(audit.theatreSeconds)) theatre", tint: .orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func signalRow(_ signal: VerificationSignal) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.id).font(.caption.weight(.medium))
                Text("\(LoopFormat.seconds(signal.latencySeconds)) · \(signal.legibility.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.4f", signal.passEvidencePerSecond))
                .font(.caption.monospacedDigit())
                .foregroundStyle(signal.isInformative ? .primary : .secondary)
        }
    }

    // MARK: - Small pieces

    private func metric(title: String, value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(tint)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func icon(for verdict: LoopVerdict) -> String {
        switch verdict {
        case .close: return "checkmark.seal.fill"
        case .escalate: return "hand.raised.fill"
        case .park: return "pause.circle.fill"
        case .rework: return "arrow.uturn.backward.circle.fill"
        case .runNext: return "play.circle.fill"
        }
    }

    private func tint(for verdict: LoopVerdict) -> Color {
        switch verdict {
        case .close: return .green
        case .escalate: return .orange
        case .park, .rework: return .red
        case .runNext: return .blue
        }
    }

    private func headline(for verdict: LoopVerdict) -> String {
        switch verdict {
        case .close: return "Close — land it unattended"
        case .escalate: return "Escalate — a human has to look"
        case .park: return "Park"
        case .rework: return "Rework"
        case .runNext: return "Keep going"
        }
    }

    private func detail(for verdict: LoopVerdict) -> String {
        switch verdict {
        case let .close(risk, spent):
            return "\(LoopFormat.percent(risk)) residual after \(LoopFormat.seconds(spent))."
        case let .escalate(requirement):
            return requirement.rationale
        case let .park(reason):
            return reason.description
        case let .rework(fingerprint):
            return "Failing rung: \(fingerprint.signalID)."
        case let .runNext(signal):
            return "Next: \(signal.id)."
        }
    }
}

#Preview {
    VerifierLoopDemoView()
}
#endif
