import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.lukefaccin.BlinkReminder", category: "scheduler")

/// Fires `onFire` every `Settings.intervalMinutes` while you can see the screen. Pauses while
/// the Mac sleeps, the display is off or the screen is locked, and starts a fresh countdown after.
@MainActor
@Observable
final class ReminderScheduler {
    private enum PauseReason: String {
        case systemSleep, displayOff, screenLocked
    }

    private(set) var nextFireDate: Date?

    @ObservationIgnored var onFire: (() -> Void)?
    /// Called when reminders pause, so an open popover can be closed while the screen is unseen.
    @ObservationIgnored var onPause: (() -> Void)?
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pauseReasons: Set<PauseReason> = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.pause(.systemSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.resume(.systemSleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.pause(.displayOff) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.resume(.displayOff) }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.pause(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.resume(.screenLocked) }

        // The notifications only report changes, so pick up the state at launch.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { pauseReasons.insert(.displayOff) }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { pauseReasons.insert(.screenLocked) }
        if !pauseReasons.isEmpty { log.info("Starting paused: \(self.pauseReasons.map(\.rawValue).joined(separator: ", "), privacy: .public)") }
        restart()
    }

    /// Starts a fresh countdown from now using the current interval, unless reminders are paused.
    func restart() {
        timer?.invalidate()
        timer = nil
        guard pauseReasons.isEmpty else {
            nextFireDate = nil
            return
        }
        let interval = TimeInterval(settings.intervalMinutes * 60)
        nextFireDate = Date().addingTimeInterval(interval)
        log.info("Next reminder in \(Int(interval))s")
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (ReminderScheduler) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func pause(_ reason: PauseReason) {
        log.info("Pausing: \(reason.rawValue, privacy: .public)")
        pauseReasons.insert(reason)
        restart()
        onPause?()
    }

    private func resume(_ reason: PauseReason) {
        guard pauseReasons.remove(reason) != nil else { return }
        log.info("Resuming: \(reason.rawValue, privacy: .public)")
        restart()
    }

    private func fire() {
        log.info("Timer fired")
        onFire?()
        restart()
    }
}
