import HuskeKit
import SwiftUI

/// Quick controls in the system menu bar — mirrors the Python helper's menu,
/// plus a shortcut back into the app.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            statusLine
            Divider()
            if model.session.isBusy, let snap = model.session.snapshot {
                Button(snap.paused ? "Resume Recording" : "Pause Recording") {
                    model.session.pauseResume()
                }
                Button(snap.screenshotsEnabled ? "Disable Screenshots" : "Enable Screenshots") {
                    model.session.toggleScreenshots()
                }
                Button(snap.distillEnabled ? "Disable Distillation" : "Enable Distillation") {
                    model.session.toggleDistill()
                }
                Divider()
                Button("Stop Recording") {
                    model.session.requestStop()
                }
                .disabled(snap.stopping)
            } else {
                Button("Start Recording") {
                    model.startRecording()
                }
                .disabled(model.binaryMissing)
            }
            Divider()
            Button("Open Transcripts Folder") {
                if model.session.isBusy {
                    model.session.send(.openTranscripts)
                } else if let root = model.transcripts.root {
                    NSWorkspace.shared.open(root)
                }
            }
            Button("Open Huske") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Divider()
            Button("Quit Huske") {
                NSApp.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let snap = model.session.snapshot, model.session.isBusy {
            let state =
                snap.stopping
                ? "finishing…"
                : (snap.paused ? "paused" : (snap.recording ? "recording" : "idle"))
            Text(
                "\(state) · chunk \(String(format: "%03d", snap.currentChunkSeq)) · queue \(snap.queueDepth)"
            )
        } else {
            Text("not recording")
        }
    }
}
