import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.lukefaccin.BlinkReminder", category: "popover")

/// Owns the menu bar icon, the settings popover and the reminder panel that drop down from it.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let settings: Settings
    private let scheduler: ReminderScheduler
    private let activity: ActivityLog
    private let history: HistoryWindowController

    private var reminderPanel: ReminderPanel?
    private var session: ReminderSession?
    private var autoCloseTimer: Timer?
    private var showReminderAfterClose = false
    private var outsideClickMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

    init(settings: Settings, scheduler: ReminderScheduler, activity: ActivityLog) {
        self.settings = settings
        self.scheduler = scheduler
        self.activity = activity
        history = HistoryWindowController(activity: activity)
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

    /// Shows the "Look 20 Meters away" reminder without taking keyboard focus, even when clicked.
    func showReminder() {
        guard !popover.isShown, reminderPanel == nil else {
            log.info("Skipping reminder: already showing a popover or reminder")
            return
        }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        log.info("Showing reminder")
        let session = ReminderSession(duration: TimeInterval(settings.displaySeconds))
        self.session = session
        let panel = ReminderPanel(rootView: ReminderView(
            session: session,
            onStart: { [weak self] in self?.startCountdown() },
            onDismiss: { [weak self] in self?.closeReminder() }
        ))
        panel.show(below: buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)))
        reminderPanel = panel
        startWatchingForOutsideInteraction()

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
                self.closeReminder(completed: true)
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

    private func closeReminder(completed: Bool = false) {
        guard let reminderPanel else { return }
        log.info("Reminder closed")
        let outcome: RestOutcome = completed ? .completed : session?.startedAt != nil ? .cutShort : .skipped
        activity.recordRest(outcome, intervalMinutes: settings.intervalMinutes)
        reminderPanel.orderOut(nil)
        self.reminderPanel = nil
        session = nil
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        stopWatchingForOutsideInteraction()
    }

    /// Closes without animating. A close animation never finishes while the display is off,
    /// which would leave `isShown` stuck at true and block every later reminder.
    func closeImmediately() {
        closeReminder()
        guard popover.isShown else { return }
        showReminderAfterClose = false
        popover.animates = false
        popover.close()
        popover.animates = true
        stopWatchingForOutsideInteraction()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if reminderPanel != nil {
            closeReminder()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        showSettings()
    }

    private func showSettings() {
        guard let button = statusItem.button else { return }
        let hostingView = NSHostingView(rootView: SettingsView(settings: settings, scheduler: scheduler, activity: activity, onRemindNow: { [weak self] in
            guard let self else { return }
            // The close animates and isShown stays true until it finishes, so show the
            // reminder from popoverDidClose rather than straight away.
            showReminderAfterClose = true
            scheduler.restart()
            popover.performClose(nil)
        }, onShowHistory: { [weak self] in
            guard let self else { return }
            popover.performClose(nil)
            history.show()
        }))
        let controller = NSViewController()
        controller.view = hostingView
        popover.contentViewController = controller
        popover.contentSize = hostingView.fittingSize

        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startWatchingForOutsideInteraction()
    }

    /// The reminder never activates the app, and `.transient` only closes the popover while
    /// this app is active, so close both on clicks in other apps or app switches.
    private func startWatchingForOutsideInteraction() {
        stopWatchingForOutsideInteraction()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    private func closeAll() {
        closeReminder()
        popover.performClose(nil)
    }

    private func stopWatchingForOutsideInteraction() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }
        outsideClickMonitor = nil
        appActivationObserver = nil
    }

    func popoverDidClose(_ notification: Notification) {
        log.info("Popover closed")
        stopWatchingForOutsideInteraction()

        if showReminderAfterClose {
            showReminderAfterClose = false
            DispatchQueue.main.async { [weak self] in self?.showReminder() }
        }
    }
}

/// A popover-styled panel for the reminder. Clicking an `NSPopover` activates the app and
/// takes keyboard focus from whatever you're typing in, so the reminder uses a panel that
/// never activates the app or becomes the key window.
private final class ReminderPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let hostingView = FirstMouseHostingView(rootView: rootView)
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(hostingView)
        hostingView.frame.size = hostingView.fittingSize
        background.frame.size = hostingView.fittingSize
        contentView = background
        setContentSize(hostingView.fittingSize)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel centred under `anchor`, a rect in screen coordinates, kept on screen.
    func show(below anchor: NSRect) {
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame
        var origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.minY - 6 - frame.height)
        if let visible {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 8 - frame.width)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}

/// The reminder panel is never active, so let its first click press Start or Dismiss.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
