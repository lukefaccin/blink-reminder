<h1 align="center">👓 Blink Reminder</h1>

A tiny macOS menu bar app that reminds you to rest your eyes. A common rule of thumb is looking 20 meters in the distance for 20 seconds. A glasses icon sits in the menu bar, and every 20 minutes a popover drops down from it saying **"Look 20 Meters away"**.

- Press **Start** and look away. A sound plays as the countdown starts, and another when it ends and the popover closes. You can turn on **Start countdown automatically** to skip the click.
- The reminder also closes when you click another window, switch apps, or press **Dismiss**.
- Click the glasses icon to set how often reminders appear (1–120 min) and how long to look away (5–120 s), by typing a value or using the arrows. You can also toggle auto-start and sounds, trigger a reminder now, or quit.
- There's no Dock icon. Reminders pause while the Mac sleeps, the display is off or the screen is locked, and a fresh countdown starts when you're back.

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode isn't needed.

## Install with Homebrew

```bash
brew tap lukefaccin/tap
brew trust --tap lukefaccin/tap      # Homebrew 7.0.11+ ignores untrusted taps
brew install blink-reminder
brew services start blink-reminder   # run now and at every login
```

## Build from source

```bash
scripts/build-app.sh
open build/BlinkReminder.app
```

To keep it, copy `build/BlinkReminder.app` to `/Applications`.

## Layout

| File | Purpose |
| --- | --- |
| `Sources/BlinkReminder/StatusBarController.swift` | Menu bar icon, popover, and close-on-outside-click |
| `Sources/BlinkReminder/ReminderScheduler.swift` | Reminder timer, paused across sleep |
| `Sources/BlinkReminder/Settings.swift` | Interval and display time, stored in `UserDefaults` |
| `Sources/BlinkReminder/ReminderView.swift` / `SettingsView.swift` | SwiftUI popover content |
| `scripts/build-app.sh` | Compiles with `swiftc` and assembles the `.app` bundle |

The app is built with `swiftc` instead of SwiftPM, and it avoids SwiftUI's `@State` macro. With only the Command Line Tools installed, SwiftPM's manifest library and SwiftUI's macro plugins aren't available.

## License

[Apache License 2.0](LICENSE)
