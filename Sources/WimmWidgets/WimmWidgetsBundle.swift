import SwiftUI
import WidgetKit
import AppIntents

/// Control Center / Lock Screen / Action button control that starts a
/// recording. The intent itself runs in the app (`openAppWhenRun`).
@main
struct WimmWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingControl()
    }
}

struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.micha.wimm.control.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Wimm Record")
        .description("Opens Wimm and starts a new voice note.")
    }
}
