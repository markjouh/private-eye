import AppIntents
import SwiftUI
import WidgetKit

/// Buttons the user can put on the Lock Screen (the two slots at its bottom corners, where the
/// torch and the camera usually sit), in Control Center, or on the Action button. Each opens
/// Private Eye and runs one of its intents there (`Eyes/Intents/EyesIntents.swift`, which is
/// compiled into this extension too so that the buttons can name them).
///
/// Nothing runs in this extension: the camera and the models live in the app, so every intent asks
/// for the foreground. From a locked phone that means Face ID or the passcode first, as for any app.
@main
struct EyesControls: WidgetBundle {
    var body: some Widget {
        DescribeControl()
        AskControl()
        FindControl()
    }
}

/// The one to put where the camera button is: one press, and the app says what is ahead.
struct DescribeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.eyeshack.eyes.controls.describe") {
            ControlWidgetButton(action: DescribeAheadIntent()) {
                Label("Describe", systemImage: "eye")
            }
        }
        .displayName("Describe What's Ahead")
        .description("Opens Private Eye and says what is in front of the camera.")
    }
}

struct AskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.eyeshack.eyes.controls.ask") {
            ControlWidgetButton(action: AskQuestionIntent()) {
                Label("Ask", systemImage: "mic")
            }
        }
        .displayName("Ask a Question")
        .description("Opens Private Eye and starts listening. Press again to stop and hear the answer.")
    }
}

/// A control cannot ask a question when it is pressed, so what to look for is chosen once, when
/// the control is added: "my keys", "Dana", "a chair".
struct FindControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.eyeshack.eyes.controls.find", intent: FindControlSettings.self) { settings in
            ControlWidgetButton(action: FindIntent(target: settings.target)) {
                Label("Find \(settings.target)", systemImage: "binoculars")
            }
        }
        .displayName("Find Something")
        .description("Opens Private Eye and looks for the thing you choose, such as \"my keys\", beeping until it finds it.")
        .promptsForUserConfiguration()
    }
}

struct FindControlSettings: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Find Something"

    @Parameter(title: "What to look for", default: "my keys")
    var target: String
}
