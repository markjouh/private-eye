import AppIntents

/// Carries a request from an App Intent (Action button, Shortcuts, Siri) to the running app.
///
/// An intent can run before the app can act on it: it may be what launched the app, with the model
/// still loading. So requests go through a stream that holds the latest one until `AppModel` starts
/// reading, which it does once the model is ready.
enum IntentTrigger {
    enum Request: Sendable {
        /// The same as a tap: a quick description of what is ahead.
        case describe
        /// Start listening for a question, or stop and answer if already listening.
        case toggleListening
    }

    private static let pipe = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingNewest(1))

    /// The requests, in order. A stream has a single reader: `AppModel`.
    static var requests: AsyncStream<Request> { pipe.stream }

    static func send(_ request: Request) {
        print("[eyes] intent request: \(request)")
        pipe.continuation.yield(request)
    }
}

/// The Action button's best fit. An app is never told about that button directly; the user points
/// it at one of the shortcuts below in Settings, and then it works from anywhere, app running or not.
struct DescribeAheadIntent: AppIntent {
    static let title: LocalizedStringResource = "Describe What's Ahead"
    static let description = IntentDescription("Opens Private Eye and says what is in front of the camera.")
    /// The camera only runs while the app is in front, so the system brings it there first.
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        IntentTrigger.send(.describe)
        return .result()
    }
}

/// A shortcut runs once per press and never learns how long the button was held, so there is no
/// hold-to-talk here. Instead the first run starts listening and the next one stops.
struct AskQuestionIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Question"
    static let description = IntentDescription("Opens Private Eye and starts listening. Run it again to stop and hear the answer.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        IntentTrigger.send(.toggleListening)
        return .result()
    }
}

/// Publishes the intents as ready-made shortcuts, so they show up in the Shortcuts app, in Siri and
/// in the Action button's shortcut picker without the user building anything.
struct EyesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DescribeAheadIntent(),
            phrases: ["Describe what's ahead with \(.applicationName)", "Ask \(.applicationName) what's ahead"],
            shortTitle: "Describe What's Ahead",
            systemImageName: "eye")
        AppShortcut(
            intent: AskQuestionIntent(),
            phrases: ["Ask \(.applicationName) a question"],
            shortTitle: "Ask a Question",
            systemImageName: "mic")
    }
}
