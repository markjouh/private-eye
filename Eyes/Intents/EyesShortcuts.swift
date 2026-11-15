import AppIntents

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
        AppShortcut(
            intent: FindIntent(),
            phrases: ["Find something with \(.applicationName)", "Look for something with \(.applicationName)"],
            shortTitle: "Find Something",
            systemImageName: "binoculars")
    }
}
