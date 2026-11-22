import AppIntents
import SwiftUI
import UIKit

@main
struct HuskeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .tint(Brand.amber)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGTaskScheduler requires registration before launch completes.
        BackgroundSync.register {
            await AppModel.shared.sync.runBackgroundPass()
        }
        // An App Intent (Action button, Shortcuts) can be why we launched, in
        // the background: build the model now so the recorder is listening.
        _ = AppModel.shared
        // Keep Siri / Spotlight / the Action button's list current.
        HuskeShortcuts.updateAppShortcutParameters()
        return true
    }
}
