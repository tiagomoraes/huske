import SwiftUI
import WidgetKit

@main
struct HuskeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
    }
}

/// Control Center, Lock Screen and Action button control (Settings › Action
/// Button › Controls › Huske). One press starts a recording in the background;
/// the next stops and saves it. The Dynamic Island shows which state it is in.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "cloud.tiagomoraes.huske.ios.start-recording") {
            ControlWidgetButton(action: RecordControlIntent()) {
                Label("Record", systemImage: "record.circle")
            }
        }
        .displayName("Huske Record")
        .description("Starts a recording without opening Huske. Press again to stop and save it.")
    }
}
