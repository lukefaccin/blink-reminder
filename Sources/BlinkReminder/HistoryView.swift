import AppKit
import Charts
import Observation
import SwiftUI

/// Symptom picks not yet logged. It lives outside the view because SwiftUI's `@State`
/// macro isn't available with only the Command Line Tools.
@MainActor
@Observable
final class SymptomDraft {
    var severities: [Symptom: Int] = [:]
    var loggedAt: Date?
}

/// Owns the history window, reusing it across opens.
@MainActor
final class HistoryWindowController {
    private let activity: ActivityLog
    private let draft = SymptomDraft()
    private var window: NSWindow?

    init(activity: ActivityLog) {
        self.activity = activity
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // A menu bar app isn't active by default, so the window would otherwise open behind others.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: HistoryView(activity: activity, draft: draft)
        ))
        window.title = "Blink Reminder History"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct HistoryView: View {
    static let chartDays = 30
    static let tableDays = 7

    let activity: ActivityLog
    let draft: SymptomDraft

    var body: some View {
        let summaries = activity.summaries(days: Self.chartDays)
        VStack(alignment: .leading, spacing: 18) {
            SymptomForm(activity: activity, draft: draft)
            Divider()
            CorrelationSection(summaries: summaries)
            Divider()
            RecentDaysTable(summaries: Array(summaries.suffix(Self.tableDays)))
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct SymptomForm: View {
    let activity: ActivityLog
    let draft: SymptomDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How do your eyes feel?")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(Symptom.allCases) { symptom in
                    GridRow {
                        Text(symptom.title)
                        Picker(symptom.title, selection: severity(of: symptom)) {
                            ForEach(SymptomEntry.severityLabels.indices, id: \.self) { index in
                                Text(SymptomEntry.severityLabels[index]).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            HStack {
                if let loggedAt = draft.loggedAt {
                    Text("Logged at \(loggedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Log symptoms") {
                    activity.recordSymptoms(Dictionary(uniqueKeysWithValues: Symptom.allCases.map {
                        ($0, draft.severities[$0] ?? 0)
                    }))
                    draft.loggedAt = .now
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func severity(of symptom: Symptom) -> Binding<Int> {
        Binding(
            get: { draft.severities[symptom] ?? 0 },
            set: { draft.severities[symptom] = $0 }
        )
    }
}

private struct CorrelationSection: View {
    let summaries: [DaySummary]

    var body: some View {
        let correlation = RestSymptomCorrelation(summaries)
        let paired = summaries.filter { $0.restsPerHour != nil && $0.symptomScore != nil }

        VStack(alignment: .leading, spacing: 10) {
            Text("Breaks and symptoms, last \(HistoryView.chartDays) days")
                .font(.headline)

            Chart(paired) { day in
                PointMark(
                    x: .value("Breaks per screen hour", day.restsPerHour ?? 0),
                    y: .value("Symptom score", day.symptomScore ?? 0)
                )
            }
            .chartXAxisLabel("Breaks per screen hour")
            .chartYAxisLabel("Symptom score")
            .chartYScale(domain: 0...SymptomEntry.maxScore)
            .frame(height: 180)

            Text(headline(correlation))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = detail(correlation) {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headline(_ correlation: RestSymptomCorrelation) -> String {
        guard correlation.pairedDays >= RestSymptomCorrelation.minimumDays else {
            return "Log symptoms on \(RestSymptomCorrelation.minimumDays) days with at least half an hour "
                + "at the screen to compare them with your breaks. \(correlation.pairedDays) so far."
        }
        guard let r = correlation.coefficient else {
            return "Your breaks or symptoms haven't varied enough to compare yet."
        }
        if r <= -0.3 { return "Symptoms tend to be milder on days you take more breaks." }
        if r >= 0.3 {
            return "Symptoms tend to be worse on days you take more breaks. Sore eyes may be "
                + "prompting the breaks, rather than the other way round."
        }
        return "No clear link yet between your breaks and symptoms."
    }

    private func detail(_ correlation: RestSymptomCorrelation) -> String? {
        guard let median = correlation.medianRate,
              let above = correlation.scoreAtOrAboveMedian else { return nil }
        var text = "At \(oneDecimal(median)) or more breaks an hour, your average symptom score was "
            + "\(oneDecimal(above)) out of \(SymptomEntry.maxScore)"
        if let below = correlation.scoreBelowMedian {
            text += ", against \(oneDecimal(below)) on other days"
        }
        if let r = correlation.coefficient {
            text += ". Correlation \(r.formatted(.number.precision(.fractionLength(2)))) "
                + "over \(correlation.pairedDays) days"
        }
        return text + "."
    }
}

private struct RecentDaysTable: View {
    let summaries: [DaySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(summaries.count) days")
                .font(.headline)

            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Day").gridColumnAlignment(.leading)
                    Text("Breaks")
                    Text("Missed")
                    Text("Screen")
                    Text("Symptoms")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(summaries.reversed()) { day in
                    GridRow {
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated).day()))
                        Text("\(day.completed)")
                        Text("\(day.missed)")
                        Text(Duration.seconds(day.screenHours * 3600)
                            .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                        Text(day.symptomScore.map(oneDecimal) ?? "-")
                    }
                    .monospacedDigit()
                }
            }
        }
    }
}

private func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
}
