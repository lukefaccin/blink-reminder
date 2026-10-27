import Foundation
import Observation

/// User preferences, persisted to UserDefaults.
@MainActor
@Observable
final class Settings {
    static let intervalRange = 1...120
    static let displayRange = 5...120
    static let defaultInterval = 20
    static let defaultDisplay = 20

    private enum Keys {
        static let interval = "intervalMinutes"
        static let display = "displaySeconds"
        static let autoStart = "autoStartCountdown"
        static let playSounds = "playSounds"
    }

    /// How often the reminder appears, in minutes.
    var intervalMinutes: Int {
        didSet {
            // Number fields write back unchanged values when their view is torn down,
            // which would otherwise restart the countdown.
            guard intervalMinutes != oldValue else { return }
            defaults.set(intervalMinutes, forKey: Keys.interval)
            onIntervalChange?()
        }
    }

    /// How long the look-away countdown runs, in seconds.
    var displaySeconds: Int {
        didSet { defaults.set(displaySeconds, forKey: Keys.display) }
    }

    /// Starts the countdown as soon as the reminder appears instead of waiting for Start.
    var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: Keys.autoStart) }
    }

    /// Plays a sound when the countdown starts and when it ends.
    var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.playSounds) }
    }

    @ObservationIgnored var onIntervalChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.integer(forKey: Keys.interval)
        let display = defaults.integer(forKey: Keys.display)
        intervalMinutes = Self.intervalRange.contains(interval) ? interval : Self.defaultInterval
        displaySeconds = Self.displayRange.contains(display) ? display : Self.defaultDisplay
        autoStart = defaults.bool(forKey: Keys.autoStart)
        playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? true
    }
}
