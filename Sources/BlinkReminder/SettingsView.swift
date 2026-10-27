import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    let scheduler: ReminderScheduler
    let onRemindNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NumberRow(title: "Remind every", unit: "min",
                      value: clamped(\.intervalMinutes, to: Settings.intervalRange),
                      range: Settings.intervalRange, step: 1)

            NumberRow(title: "Look away for", unit: "s",
                      value: clamped(\.displaySeconds, to: Settings.displayRange),
                      range: Settings.displayRange, step: 5)

            Toggle("Start countdown automatically", isOn: $settings.autoStart)
            Toggle("Play start and end sounds", isOn: $settings.playSounds)

            if let next = scheduler.nextFireDate, next > .now {
                HStack(spacing: 4) {
                    Text("Next reminder in")
                    Text(timerInterval: Date.now...next, countsDown: true)
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Remind me now", action: onRemindNow)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Writes typed values back clamped to `range`, since the text field accepts any number.
    private func clamped(_ keyPath: ReferenceWritableKeyPath<Settings, Int>,
                         to range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

/// A label with a number field and a stepper bound to the same value.
private struct NumberRow: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
            Text(unit)
                .frame(width: 26, alignment: .leading)
        }
    }
}
