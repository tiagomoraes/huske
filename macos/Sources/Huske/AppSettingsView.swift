import SwiftUI
import UniformTypeIdentifiers

/// App-level preferences (⌘,) — everything about the *engine* lives in the
/// Configuration pane instead.
struct AppSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingBinary = false

    var body: some View {
        Form {
            Section("huske engine") {
                LabeledContent("Binary") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.binaryURL?.path ?? "not found")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.binaryURL == nil ? Theme.err : Theme.fgMuted)
                            .textSelection(.enabled)
                        HStack {
                            Button("Choose…") { pickingBinary = true }
                            Button("Auto-detect") { model.setBinaryOverride(nil) }
                        }
                        .controlSize(.small)
                    }
                }
                if let version = model.binaryVersion {
                    LabeledContent("Version") {
                        Text(version)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.fgMuted)
                    }
                }
            }
            Section {
                Text(
                    "Recording, transcription, chunking, and storage options are in "
                        + "the main window under Configuration."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.fgMuted)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fileImporter(
            isPresented: $pickingBinary,
            allowedContentTypes: [.unixExecutable, .executable, .item]
        ) { result in
            if case .success(let url) = result {
                model.setBinaryOverride(url.path)
            }
        }
    }
}
