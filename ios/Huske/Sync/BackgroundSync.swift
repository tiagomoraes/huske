// BGTaskScheduler glue: an app-refresh task (cheap, frequent) and a
// processing task that requires network (longer, for big uploads). Both just
// run one SyncManager pass. Identifiers are listed in Info.plist under
// BGTaskSchedulerPermittedIdentifiers.

import BackgroundTasks
import Foundation

enum BackgroundSync {
    static let refreshIdentifier = "cloud.tiagomoraes.huske.ios.sync-refresh"
    static let processingIdentifier = "cloud.tiagomoraes.huske.ios.sync-processing"

    /// Must run before the app finishes launching.
    static func register(run: @escaping @MainActor () async -> Void) {
        for identifier in [refreshIdentifier, processingIdentifier] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                handle(task, run: run)
            }
        }
    }

    private static func handle(_ task: BGTask, run: @escaping @MainActor () async -> Void) {
        let box = UncheckedTask(task)
        let work = Task { @MainActor in
            await run()
            box.task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    /// Asks the system for a later chance to sync. Safe to call repeatedly:
    /// a pending request with the same identifier is replaced.
    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date().addingTimeInterval(5 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    private struct UncheckedTask: @unchecked Sendable {
        let task: BGTask
        init(_ task: BGTask) { self.task = task }
    }
}
