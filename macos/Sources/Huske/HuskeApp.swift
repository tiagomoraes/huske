import HuskeKit
import SwiftUI

@main
struct HuskeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        BrandFonts.registerAll()
        if ScreenRenderer.runIfRequested() {
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .tint(Theme.amber)
                .frame(minWidth: 880, minHeight: 580)
                .task {
                    delegate.model = model
                    await model.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start Recording") { model.startRecording() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.session.isBusy || model.binaryMissing || model.engineOutdated)
                Button("Stop Recording") { model.session.requestStop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.session.isBusy)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: menuBarSymbol)
        }

        Settings {
            AppSettingsView()
                .environment(model)
                .tint(Theme.amber)
        }
    }

    private var menuBarSymbol: String {
        guard let snap = model.session.snapshot, model.session.isBusy else {
            return "waveform"
        }
        if snap.stopping { return "ellipsis.circle" }
        if snap.paused { return "pause.circle" }
        if snap.recording { return "record.circle" }
        return "waveform"
    }
}

/// Intercepts quit while a recording we own is live: asks the engine to stop
/// gracefully, lets the drain finish (the window shows progress), then quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model, model.session.ownsEngine, model.session.isBusy else {
                return .terminateNow
            }
            model.session.requestStop()
            Task { @MainActor in
                // Poll until the engine finishes draining (it caps its own
                // drain at 10 minutes; add slack, then give up and terminate).
                let deadline = Date().addingTimeInterval(11 * 60)
                while Date() < deadline, model.session.isBusy {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // recording continues with the menu bar extra
    }
}
