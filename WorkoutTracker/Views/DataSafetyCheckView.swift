//
//  DataSafetyCheckView.swift
//  WorkoutTracker
//
//  Screen 11 (optional). Runs read-only integrity checks that verify the core
//  data-safety invariants and reports pass/fail. Never mutates data.
//

import SwiftUI
import SwiftData

struct DataSafetyCheckView: View {
    @Environment(\.modelContext) private var context
    @State private var checks: [IntegrityCheck] = []

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: allPass ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(allPass ? .green : .red)
                        .font(.title)
                    Text(allPass ? "All integrity checks passing" : "Some checks need attention")
                        .font(.headline)
                }
            }
            ForEach(checks) { check in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                        Text(check.title).font(.subheadline.bold())
                    }
                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Data Safety Check")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { run() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear(perform: run)
    }

    private var allPass: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }

    private func run() {
        checks = DataIntegrityService(context).runAll()
    }
}
