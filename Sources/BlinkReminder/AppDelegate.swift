import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings?
    private var scheduler: ReminderScheduler?
    private var statusBar: StatusBarController?
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no visible windows, so App Nap would otherwise defer its timers.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Timing eye-rest reminders"
        )

        let settings = Settings()
        let scheduler = ReminderScheduler(settings: settings)
        let statusBar = StatusBarController(settings: settings, scheduler: scheduler)

        scheduler.onFire = { [weak statusBar] in statusBar?.showReminder() }
        scheduler.onPause = { [weak statusBar] in statusBar?.closeImmediately() }
        settings.onIntervalChange = { [weak scheduler] in scheduler?.restart() }
        scheduler.start()

        self.settings = settings
        self.scheduler = scheduler
        self.statusBar = statusBar
    }
}
