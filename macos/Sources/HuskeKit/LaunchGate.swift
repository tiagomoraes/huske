// The app's start-up work — probe the engine, start receiving from paired
// iPhones, honour "start recording when Huske opens" — ran only from the main
// window's task. A login item, or a main window that was closed when Huske
// last quit, launches with no window at all: nothing started, and a paired
// iPhone could not reach the Mac until someone opened the window.
//
// So the app delegate starts it at launch, window or not. This gate keeps the
// two callers from doing it twice: a window that appears while the launch run
// is still going joins it; a window opened later runs the work again, as it
// always has (the engine may have been upgraded in the meantime).

import Foundation

@MainActor
public final class LaunchGate {
    private var launch: Task<Void, Never>?
    private var launchFinished = false

    public init() {}

    /// The app finished launching. Runs `work` once; later calls do nothing.
    public func startAtLaunch(_ work: @escaping @MainActor () async -> Void) {
        guard launch == nil else { return }
        launch = Task { @MainActor [weak self] in
            await work()
            self?.launchFinished = true
        }
    }

    /// The main window appeared. Whichever of the two callers comes first
    /// starts the launch run; while it is in flight the window waits for it
    /// instead of running the work a second time.
    public func runFromWindow(_ work: @escaping @MainActor () async -> Void) async {
        if launch == nil { startAtLaunch(work) }
        if let launch, !launchFinished {
            await launch.value
            return
        }
        await work()
    }
}
