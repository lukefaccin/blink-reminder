import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.lukefaccin.BlinkReminder", category: "popover")

/// Owns the menu bar icon and the popover that drops down from it.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let settings: Settings
    private let scheduler: ReminderScheduler

    private var session: ReminderSession?
    private var autoCloseTimer: Timer?
    private var showReminderAfterClose = false
    private var outsideClickMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

    init(settings: Settings, scheduler: ReminderScheduler) {
        self.settings = settings
        self.scheduler = scheduler
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Blink Reminder")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    /// Shows the "Look 20 Meters away" popover without stealing keyboard focus.
    func showReminder() {
        guard !popover.isShown else {
            log.info("Skipping reminder: popover already shown")
            return
        }
        log.info("Showing reminder")
        let session = ReminderSession(duration: TimeInterval(settings.displaySeconds))
        self.session = session
        show(ReminderView(
            session: session,
            onStart: { [weak self] in self?.startCountdown() },
            onDismiss: { [weak self] in self?.popover.performClose(nil) }
        ), activate: false)

        if settings.autoStart { startCountdown() }
    }

    /// Starts the look-away countdown. When it finishes, the end sound plays and the popover closes.
    private func startCountdown() {
        guard let session, session.startedAt == nil else { return }
        log.info("Starting \(Int(session.duration))s countdown")
        session.startedAt = .now
        playSound("Pop")

        let timer = Timer(timeInterval: session.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                log.info("Countdown finished")
                self.playSound("Glass")
                self.popover.performClose(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
    }

    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        if NSSound(named: NSSound.Name(name))?.play() != true {
            log.error("Couldn't play sound \(name, privacy: .public)")
        }
    }

    /// Closes without animating. A close animation never finishes while the display is off,
    /// which would leave `isShown` stuck at true and block every later reminder.
    func closeImmediately() {
        guard popover.isShown else { return }
        showReminderAfterClose = false
        popover.animates = false
        popover.close()
        popover.animates = true
        session = nil
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        stopWatchingForOutsideInteraction()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        show(SettingsView(settings: settings, scheduler: scheduler, onRemindNow: { [weak self] in
            guard let self else { return }
            // The close animates and isShown stays true until it finishes, so show the
            // reminder from popoverDidClose rather than straight away.
            showReminderAfterClose = true
            scheduler.restart()
            popover.performClose(nil)
        }), activate: true)
    }

    private func show(_ view: some View, activate: Bool) {
        guard let button = statusItem.button else { return }
        let hostingView = FirstMouseHostingView(rootView: view)
        let controller = NSViewController()
        controller.view = hostingView
        popover.contentViewController = controller
        popover.contentSize = hostingView.fittingSize

        if activate { NSApp.activate() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startWatchingForOutsideInteraction()
    }

    /// `.transient` only closes the popover while this app is active. The reminder appears
    /// without activating the app, so also close it on clicks in other apps or app switches.
    private func startWatchingForOutsideInteraction() {
        stopWatchingForOutsideInteraction()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopWatchingForOutsideInteraction() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }
        outsideClickMonitor = nil
        appActivationObserver = nil
    }

    func popoverDidClose(_ notification: Notification) {
        log.info("Popover closed")
        session = nil
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        stopWatchingForOutsideInteraction()

        if showReminderAfterClose {
            showReminderAfterClose = false
            DispatchQueue.main.async { [weak self] in self?.showReminder() }
        }
    }
}

/// The reminder appears without activating the app, so let its first click press Start or
/// Dismiss instead of only activating the app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
