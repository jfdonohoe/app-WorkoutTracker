//
//  DataSafetyCheckView.swift
//  WorkoutTracker
//
//  Screen 11. Runs the data-safety checks and reports pass/fail. Shown by
//  Import / Export when an import or export finds something to fix. A failing
//  check explains what to do, lists the records involved, and offers the
//  fixes that apply (DataSafetyRepair). Checks marked info are shown but
//  never counted as needing attention.
//

import SwiftUI
import SwiftData

struct DataSafetyCheckView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// What ran the check, shown under the headline, e.g. "Checked after
    /// importing your backup."
    var occasion: String = ""
    @State private var checks: [IntegrityCheck] = []
    /// A destructive fix waiting for confirmation.
    @State private var pendingFix: PendingFix?

    private struct PendingFix: Identifiable {
        let id = UUID()
        let fix: IntegrityFix
        let itemTitle: String
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: attentionCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(attentionCount == 0 ? Theme.statusGreen : Theme.statusRed)
                        .font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline).font(.headline)
                        if !occasion.isEmpty {
                            Text(occasion).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(checks) { check in
                Section {
                    checkRow(check)
                    if !check.passed {
                        failureContent(check)
                    }
                }
            }
        }
        .navigationTitle("Data Safety Check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { run() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear(perform: run)
        .confirmationDialog(pendingFix.map { "\($0.fix.label)?" } ?? "",
                            isPresented: Binding(get: { pendingFix != nil },
                                                 set: { if !$0 { pendingFix = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingFix) { pending in
            Button(pending.fix.label, role: .destructive) { apply(pending.fix) }
        } message: { pending in
            Text("\(pending.itemTitle)\n\nThis can't be undone in the app. Consider exporting a backup first (Settings › Import / Export).")
        }
    }

    private var attentionCount: Int { checks.filter(\.needsAttention).count }

    private var headline: String {
        if checks.isEmpty { return "Checking…" }
        if attentionCount > 0 {
            return attentionCount == 1 ? "1 check needs attention" : "\(attentionCount) checks need attention"
        }
        let notes = checks.filter { !$0.passed }.count
        return notes == 0 ? "All integrity checks passing" : "All clear · \(notes) note\(notes == 1 ? "" : "s")"
    }

    private func checkRow(_ check: IntegrityCheck) -> some View {
        // Icon in its own column so the detail lines up under the title.
        HStack(alignment: .firstTextBaseline) {
            statusIcon(check)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.subheadline.bold())
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PurposeButton(title: check.title, purpose: check.purpose)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ check: IntegrityCheck) -> some View {
        if check.passed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusGreen)
        } else if check.severity == .info {
            // Not an "i": that is the tappable purpose button on the same row.
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.neutralBadge)
        } else {
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.statusRed)
        }
    }

    @ViewBuilder
    private func failureContent(_ check: IntegrityCheck) -> some View {
        if let guidance = check.guidance {
            Text(guidance).font(.footnote)
        }
        if check.autoFixable {
            Button {
                DataSafetyRepair(context).autoRepair()
                saveAndRerun()
            } label: {
                // Not a Label: in a List row the icon takes the list tint
                // (green on the green button) instead of the button's white.
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("Fix")
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.statusGreen)
        }
        ForEach(check.issues) { issue in
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.title).font(.subheadline)
                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                if !issue.fixes.isEmpty {
                    HStack {
                        ForEach(issue.fixes, id: \.self) { fix in
                            Button(fix.label, role: fix.isDestructive ? .destructive : nil) {
                                if fix.isDestructive {
                                    pendingFix = PendingFix(fix: fix, itemTitle: issue.title)
                                } else {
                                    apply(fix)
                                }
                            }
                            // Several buttons in one List row must be borderless,
                            // or a tap anywhere on the row fires all of them.
                            .buttonStyle(.borderless)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(fix.isDestructive ? Theme.statusRed : Theme.statusGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill((fix.isDestructive ? Theme.statusRed : Theme.statusGreen).opacity(0.15)))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func apply(_ fix: IntegrityFix) {
        DataSafetyRepair(context).apply(fix)
        saveAndRerun()
    }

    private func saveAndRerun() {
        try? context.save()
        run()
    }

    private func run() {
        checks = DataIntegrityService(context).runAll()
        // Needing attention first, then notes, then passing; stable within each.
        checks = checks.enumerated().sorted { a, b in
            let ra = Self.rank(a.element), rb = Self.rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private static func rank(_ check: IntegrityCheck) -> Int {
        check.needsAttention ? 0 : (check.passed ? 2 : 1)
    }
}

/// The info button on each check: explains what the check protects, whether
/// or not it passes. Borderless so it doesn't make the whole row tappable.
private struct PurposeButton: View {
    let title: String
    let purpose: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(Theme.statusGreen)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(purpose).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(idealWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}
