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
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovering orphaned audio")
                        .font(.system(size: 15, weight: .bold))
                    Text("Scans for chunks a previous crash left behind and transcribes them.")
                        .font(.system(size: 11.5))
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
                                .font(.system(size: 11, design: .monospaced))
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
                    RoundedRectangle(cornerRadius: 8).fill(Theme.bgSunken.opacity(0.6))
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
                    .foregroundStyle(code == 0 ? Theme.ok : Theme.warn)
                    .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Button(model.recoverRunning ? "Run in Background" : "Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.bg)
    }
}
