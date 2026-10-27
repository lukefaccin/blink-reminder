import SwiftUI
import Observation

/// State for one reminder popup. It lives outside the view because SwiftUI's `@State`
/// macro isn't available with only the Command Line Tools.
@MainActor
@Observable
final class ReminderSession {
    let duration: TimeInterval
    var startedAt: Date?

    init(duration: TimeInterval) {
        self.duration = duration
    }
}

struct ReminderView: View {
    let session: ReminderSession
    let onStart: () -> Void
    let onDismiss: () -> Void

    private var seconds: Int { Int(session.duration) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)

            Text("Look 20 Meters away")
                .font(.title2.weight(.semibold))

            Text("Look Away for \(seconds) \(seconds == 1 ? "Second" : "Seconds")")
                .font(.callout)
                .foregroundStyle(.secondary)

            Group {
                if let startedAt = session.startedAt {
                    ProgressView(
                        timerInterval: startedAt...startedAt.addingTimeInterval(session.duration),
                        countsDown: true
                    ) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: 1)
                }
            }
            .progressViewStyle(.linear)

            HStack {
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                if session.startedAt == nil {
                    Button("Start", action: onStart)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}
