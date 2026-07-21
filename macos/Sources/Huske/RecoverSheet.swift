import SwiftUI

/// Streams `huske recover` output: transcribes orphaned audio chunks left
/// behind by a crash, without starting a new recording.
struct RecoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bandage")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovering orphaned audio")
                        .font(.brandSans(15, .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("Scans for chunks a previous crash left behind and transcribes them.")
                        .font(.brandSans(11.5))
                        .foregroundStyle(Theme.fgMuted)
                }
                Spacer()
                if model.recoverRunning {
                    ProgressView().controlSize(.small)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.recoverLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.brandMono(11))
                                .foregroundStyle(Theme.fg)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                        .fill(Theme.bgSunken.opacity(0.6))
                )
                .onChange(of: model.recoverLog.count) {
                    proxy.scrollTo(model.recoverLog.count - 1, anchor: .bottom)
                }
            }

            HStack {
                if let code = model.recoverExitCode {
                    Label(
                        code == 0 ? "Done" : "Finished with issues (exit \(code))",
                        systemImage: code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.brandSans(12, .semibold))
                    .foregroundStyle(code == 0 ? Theme.ok : Theme.warn)
                }
                Spacer()
                Button(model.recoverRunning ? "Run in Background" : "Close") {
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.bg)
    }
}
