import SwiftUI
import UniformTypeIdentifiers

/// App-level preferences (⌘,) — everything about the *engine* lives in the
/// Configuration pane instead.
struct AppSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingBinary = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Behavior") {
                Toggle(
                    "Open Huske at login",
                    isOn: Binding(
                        get: { model.openAtLogin },
                        set: { model.setOpenAtLogin($0) }
                    )
                )
                .disabled(!model.canManageLoginItem)
                if !model.canManageLoginItem {
                    Text("Available when running the packaged Huske.app.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.fgMuted)
                }
                if let error = model.loginItemError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.err)
                }
                Toggle("Start recording when Huske opens", isOn: $model.autoStartRecording)
                Text("Enable both and your Mac records from the moment you log in.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgMuted)
            }
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
