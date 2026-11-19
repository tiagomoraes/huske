import SwiftUI
import WidgetKit

@main
struct HuskeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        if #available(iOS 18.0, *) {
            StartRecordingControl()
        }
    }
}

/// Control Center / Lock Screen / Action button control: one tap opens Huske
/// and starts a recording.
@available(iOS 18.0, *)
struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "cloud.tiagomoraes.huske.ios.start-recording") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Start Huske Recording")
        .description("Opens Huske and starts a new recording.")
    }
}
