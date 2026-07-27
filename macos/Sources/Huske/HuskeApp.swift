import HuskeKit
import SwiftUI

@main
struct HuskeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()

    init() {
        BrandFonts.registerAll()
        if ScreenRenderer.runIfRequested() {
            exit(0)
        }
    }

    var body: some Scene {
        // A single reusable window (not a WindowGroup): the app has exactly
        // one main window, and a closed one must come back on Dock click.
        Window("Huske", id: "main") {
            RootView()
                .environment(model)
                .tint(Theme.amber)
                .frame(minWidth: 880, minHeight: 580)
                .task {
                    delegate.model = model
                    delegate.openMainWindow = { openWindow(id: "main") }
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
            CommandGroup(after: .sidebar) {
                Button("Command Palette…") { model.paletteVisible.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(model.binaryMissing)
                Divider()
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            menuBarLabel
        }

        Settings {
            AppSettingsView()
                .environment(model)
                .tint(Theme.amber)
        }
    }

    /// One compact brand signature whose trailing rune reflects session state.
    private var menuBarLabel: some View {
        let state = menuBarState
        return Image(nsImage: .huskeMenuBarGlyph(for: state))
            .accessibilityLabel(Text(state.accessibilityLabel))
            .help(state.accessibilityLabel)
    }

    private var menuBarState: HuskeMenuBarState {
        guard let snap = model.session.snapshot, model.session.isBusy else {
            return .idle
        }
        if snap.stopping { return .stopping }
        if snap.paused { return .paused }
        if snap.recording { return .recording }
        return .idle
    }
}

/// Intercepts quit while a recording we own is live: asks the engine to stop
/// gracefully, lets the drain finish (the window shows progress), then quits.
/// Also owns Dock-icon reopen: with the menu bar extra keeping the app alive
/// after the last window closes, a Dock click must bring the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    @MainActor var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            // Don't trust `hasVisibleWindows`: the status item's window can
            // count as visible. Look for windows that can actually be main.
            let mainish = sender.windows.filter { $0.canBecomeMain }
            if let mini = mainish.first(where: { $0.isMiniaturized }) {
                mini.deminiaturize(nil)
                return false
            }
            if mainish.contains(where: { $0.isVisible }) {
                return true // regular activation brings it forward
            }
            openMainWindow?()
            return false
        }
    }

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
