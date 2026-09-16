import HuskeKit
import SwiftUI
import UniformTypeIdentifiers

/// App-level preferences (⌘,) — everything about the *engine's* recording
/// behaviour lives in the Configuration pane instead. What belongs here is the
/// question of *which* engine, which is an app-level choice: a Mac accumulates
/// several `huske` installs and the app drives exactly one.
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
                LabeledContent("In use") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.binaryURL?.path ?? "not found")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.binaryURL == nil ? Theme.err : Theme.fgMuted)
                            .textSelection(.enabled)
                        Text(selectionSummary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.fgMuted)
                        HStack {
                            Button("Choose…") { pickingBinary = true }
                            Button("Auto-detect") { model.clearBinaryOverride() }
                                .disabled(model.binaryOverride == nil)
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
                if let reason = model.engineFailureReason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.err)
                }
                // With one install this is noise; with two it is the answer to
                // "why is Huske running a version I already upgraded past?".
                if model.engineCandidates.count > 1 {
                    ForEach(model.engineCandidates, id: \.url) { candidate in
                        engineRow(candidate)
                    }
                    Text(
                        "Auto-detect drives the newest engine it finds. Choosing one pins it "
                            + "until you switch back."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgMuted)
                }
            }

            Section("Updates") {
                LabeledContent("Huske.app") {
                    Text("v\(model.appVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.fgMuted)
                }
                Toggle("Check for new versions automatically", isOn: $model.checkForAppUpdates)
                Text(
                    "Once a day Huske asks GitHub for the latest release number — nothing else "
                        + "is sent, and no audio, transcript, or identifier leaves this Mac. "
                        + "HUSKE_NO_UPDATE_CHECK=1 switches it off for the app and the engine "
                        + "alike."
                )
                .font(.system(size: 11))
                .foregroundStyle(Theme.fgMuted)
                HStack(spacing: 8) {
                    Button("Check Now") { model.checkForAppUpdatesNow() }
                        .controlSize(.small)
                        .disabled(model.appUpdateChecking)
                    if model.appUpdateChecking {
                        ProgressView().controlSize(.small)
                    }
                }
                updateStatus
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
        .frame(width: 520)
        .fileImporter(
            isPresented: $pickingBinary,
            allowedContentTypes: [.unixExecutable, .executable, .item]
        ) { result in
            if case .success(let url) = result {
                model.setBinaryOverride(url.path)
            }
        }
    }

    private var selectionSummary: String {
        if model.binaryOverride != nil {
            return "pinned to this path"
        }
        let count = model.engineCandidates.count
        return count > 1 ? "auto-detected — newest of \(count) installed" : "auto-detected"
    }

    @ViewBuilder
    private func engineRow(_ candidate: EngineCandidate) -> some View {
        let inUse =
            candidate.url.resolvingSymlinksInPath()
            == model.binaryURL?.resolvingSymlinksInPath()
        LabeledContent {
            if inUse {
                Text("in use")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgMuted)
            } else {
                Button("Use") { model.useEngine(candidate) }
                    .controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("huske " + (candidate.version?.description ?? "— no version"))
                    .font(.system(size: 12, weight: inUse ? .semibold : .regular))
                    .foregroundStyle(candidate.version == nil ? Theme.err : Theme.fg)
                Text(EngineSwitchRow.tildeAbbreviated(candidate.origin))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        if let update = model.appUpdate {
            HStack(spacing: 8) {
                Text("Huske \(update.tag) is available.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg)
                Link("Download", destination: update.downloadURL ?? update.pageURL)
                    .font(.system(size: 11))
                Link("Release notes", destination: update.pageURL)
                    .font(.system(size: 11))
            }
        } else if model.appUpdateAsked, !model.appUpdateChecking {
            Text("Huske is up to date.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fgMuted)
        }
    }
}
