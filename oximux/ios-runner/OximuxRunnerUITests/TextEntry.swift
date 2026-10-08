import XCTest

/// Typing into whatever has the keyboard focus.
enum TextEntry {
    static let maxText = 4000

    static func type(_ command: RunnerCommand) throws -> Done {
        let text = try command.require(command.string("text"), "text")
        guard !text.isEmpty, text.count <= maxText else { throw RunnerError.badRequest("`text` is 1–\(maxText) characters") }
        let (app, reactivated) = try Commands.target(command, gesture: true)
        try focused(command, app).typeText(text)
        return Done(reactivated: reactivated)
    }

    static func typeReturn(_ command: RunnerCommand) throws -> Done {
        let (app, reactivated) = try Commands.target(command, gesture: true)
        try focused(command, app).typeText("\n")
        return Done(reactivated: reactivated)
    }

    static func delete(_ command: RunnerCommand) throws -> Done {
        let count = try command.integer("count", in: 1...500, fallback: 1)
        let (app, reactivated) = try Commands.target(command, gesture: true)
        try focused(command, app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        return Done(reactivated: reactivated)
    }

    /// Spotlight's search field lives in its own process, over the home
    /// screen: typing "on the home screen" goes there.
    static let homeScreenOwners = [Commands.springboard, "com.apple.Spotlight"]

    /// Apple's own apps. OxiMux's target picker lists the user's apps only,
    /// so one of these opened from the home screen is still addressed as the
    /// home screen: the one in front may hold the focus.
    static let appleApps = [
        "com.apple.mobilesafari", "com.apple.Preferences", "com.apple.mobilenotes", "com.apple.MobileSMS",
        "com.apple.mobilemail", "com.apple.Maps", "com.apple.mobileslideshow", "com.apple.reminders",
        "com.apple.mobilecal", "com.apple.MobileAddressBook", "com.apple.DocumentsApp", "com.apple.AppStore",
        "com.apple.Music", "com.apple.mobilephone", "com.apple.facetime", "com.apple.weather",
        "com.apple.calculator", "com.apple.mobiletimer", "com.apple.Health", "com.apple.shortcuts",
        "com.apple.podcasts", "com.apple.iBooks", "com.apple.tv", "com.apple.stocks", "com.apple.freeform",
        "com.apple.journal", "com.apple.Passwords", "com.apple.Translate", "com.apple.findmy",
        "com.apple.news", "com.apple.VoiceMemos", "com.apple.Fitness", "com.apple.Home",
    ]

    /// The app that has the keyboard focus: the one addressed, else the one
    /// of the home screen's or Apple's in front. Asked before typing because
    /// `typeText` with nothing focused fails inside XCTest, and its handling
    /// of that failure (idle waits, two retries, diagnostics) makes the phone
    /// drop off USB for seconds — measured: three or four re-enumerations,
    /// each one cutting OxiMux's connection and the screen capture. Only an
    /// app in front is searched: querying a suspended one blocks for 30 s.
    static func focused(_ command: RunnerCommand, _ app: XCUIApplication) throws -> XCUIApplication {
        let addressed = command.string("app") ?? Commands.springboard
        if hasFocus(app) {
            return app
        }
        for bundle in homeScreenOwners + appleApps where bundle != addressed {
            let other = XCUIApplication(bundleIdentifier: bundle)
            if other.state == .runningForeground && hasFocus(other) {
                return other
            }
        }
        throw RunnerError.noKeyboardFocus
    }

    private static func hasFocus(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == 1")).count > 0
    }
}
