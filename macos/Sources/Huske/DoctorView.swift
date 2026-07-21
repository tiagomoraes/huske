import HuskeKit
import SwiftUI

struct DoctorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let error = model.doctorError {
                    Card {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.err)
                            .font(.system(size: 12))
                    }
                }
                if let report = model.doctorReport {
                    checksCard(report)
                    devicesCard(report)
                } else if !model.doctorRunning && model.doctorError == nil {
                    emptyState
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Doctor")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Environment check")
                    .font(.system(size: 17, weight: .bold))
                Text("Validates audio devices, permissions, models, and write paths.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fgMuted)
            }
            Spacer()
            if model.doctorRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("listening to the mic for a second…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.fgMuted)
                }
            } else {
                Button {
                    model.runDoctor()
                } label: {
                    Label(model.doctorReport == nil ? "Run Checks" : "Run Again", systemImage: "stethoscope")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var emptyState: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.fgFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No results yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Run the checks after installing, changing audio devices, or granting permissions.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fgMuted)
                }
            }
        }
    }

    private func checksCard(_ report: DoctorReport) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel("Checks")
                    Spacer()
                    Text(report.ok ? "all passed" : "issues found")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(report.ok ? Theme.ok : Theme.err)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                ForEach(Array(report.checks.enumerated()), id: \.offset) { index, check in
                    if index > 0 {
                        Divider().overlay(Theme.divider).padding(.leading, 44)
                    }
                    CheckRow(check: check)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func devicesCard(_ report: DoctorReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Input devices")
                ForEach(report.inputDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.fgMuted)
                        Text(device.name)
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(device.channels)ch · \(Int(device.sampleRate)) Hz")
                            .meterFigure(size: 11)
                            .foregroundStyle(Theme.fgFaint)
                    }
                }
            }
        }
    }
}

struct CheckRow: View {
    let check: DoctorCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(check.ok ? Theme.ok : Theme.err)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(check.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(check.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fgMuted)
                        .textSelection(.enabled)
                }
                if !check.ok, let hint = check.hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warn)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
