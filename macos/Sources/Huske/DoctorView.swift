import HuskeKit
import SwiftUI

struct DoctorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScroll {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(
                    "Doctor",
                    subtitle: "Validates audio devices, permissions, models, and write paths."
                ) {
                    if model.doctorRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("listening to the mic for a second…")
                                .font(.brandSans(11.5))
                                .foregroundStyle(Theme.fgMuted)
                        }
                    } else {
                        Button {
                            model.runDoctor()
                        } label: {
                            Label(model.doctorReport == nil ? "Run Checks" : "Run Again",
                                  systemImage: "stethoscope")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 30)

                if let error = model.doctorError {
                    Card {
                        Label {
                            Text(error).font(.brandSans(12.5))
                        } icon: {
                            Image(systemName: "xmark.octagon.fill")
                        }
                        .foregroundStyle(Theme.err)
                    }
                }
                if let report = model.doctorReport {
                    checksCard(report)
                    devicesCard(report)
                } else if !model.doctorRunning && model.doctorError == nil {
                    emptyState
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
    }

    private var emptyState: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.fgFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No results yet")
                        .font(.brandSans(13, .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("Run the checks after installing, changing audio devices, or granting permissions.")
                        .font(.brandSans(12))
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
                        .font(.brandMono(11, .medium))
                        .foregroundStyle(report.ok ? Theme.ok : Theme.err)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                ForEach(Array(report.checks.enumerated()), id: \.offset) { index, check in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.divider)
                            .frame(height: 1)
                            .padding(.leading, 44)
                    }
                    CheckRow(check: check)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func devicesCard(_ report: DoctorReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("Input devices")
                ForEach(report.inputDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.fgMuted)
                        Text(device.name)
                            .font(.brandSans(12.5))
                            .foregroundStyle(Theme.fg)
                        Spacer()
                        Text("\(device.channels)ch · \(Int(device.sampleRate)) Hz")
                            .font(.brandMono(11))
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
                .font(.system(size: 12))
                .foregroundStyle(check.ok ? Theme.ok : Theme.err)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(check.name)
                        .font(.brandMono(12, .medium))
                        .foregroundStyle(Theme.fg)
                    Text(check.detail)
                        .font(.brandSans(12.5))
                        .foregroundStyle(Theme.fgMuted)
                        .textSelection(.enabled)
                }
                if !check.ok, let hint = check.hint {
                    Text(hint)
                        .font(.brandSans(12))
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
