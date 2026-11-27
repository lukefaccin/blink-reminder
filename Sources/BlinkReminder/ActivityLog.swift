import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.lukefaccin.BlinkReminder", category: "activity")

enum RestOutcome: String, Codable {
    /// The look-away countdown ran to the end.
    case completed
    /// Started, then closed before the countdown ended.
    case cutShort
    /// Closed without starting the countdown.
    case skipped
}

struct RestEvent: Codable {
    let date: Date
    let outcome: RestOutcome
    let intervalMinutes: Int
}

enum Symptom: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable {
    case dryness, strain, blurriness, headache

    var id: Self { self }

    var title: String {
        switch self {
        case .dryness: "Dry or gritty eyes"
        case .strain: "Tired or sore eyes"
        case .blurriness: "Blurred vision"
        case .headache: "Headache"
        }
    }
}

struct SymptomEntry: Codable {
    static let severityLabels = ["None", "Mild", "Moderate", "Severe"]
    static let maxScore = Symptom.allCases.count * (severityLabels.count - 1)

    let date: Date
    /// Severity per symptom, from 0 (none) to 3 (severe).
    let severities: [Symptom: Int]

    var score: Int { severities.values.reduce(0, +) }
}

/// One local calendar day of rests, screen time and symptoms.
struct DaySummary: Identifiable {
    let day: Date
    let completed: Int
    let missed: Int
    let screenHours: Double
    /// Mean symptom score of the entries logged that day, or nil if none were logged.
    let symptomScore: Double?

    var id: Date { day }

    /// Rests per hour of screen time. Nil below half an hour, where one rest swings the rate too far.
    var restsPerHour: Double? {
        screenHours >= 0.5 ? Double(completed) / screenHours : nil
    }
}

/// Records each reminder's outcome, time spent at the screen and logged symptoms, persisted
/// as JSON in Application Support.
@MainActor
@Observable
final class ActivityLog {
    private struct Stored: Codable {
        var rests: [RestEvent] = []
        var symptoms: [SymptomEntry] = []
        /// Seconds the screen was in use, keyed by local day as `yyyy-MM-dd`.
        var screenSeconds: [String: TimeInterval] = [:]
    }

    private static let retentionDays = 365

    private var stored: Stored
    /// When the current stretch of screen use began. Time since then isn't in `screenSeconds` yet.
    @ObservationIgnored private var activeSince: Date?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var symptoms: [SymptomEntry] { stored.symptoms }

    init(fileURL: URL = ActivityLog.defaultFileURL) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            stored = try decoder.decode(Stored.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            stored = Stored()
        } catch {
            log.error("Couldn't read activity log: \(error, privacy: .public)")
            stored = Stored()
        }
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "BlinkReminder", directoryHint: .isDirectory)
            .appending(path: "activity.json")
    }

    func recordRest(_ outcome: RestOutcome, intervalMinutes: Int) {
        stored.rests.append(RestEvent(date: .now, outcome: outcome, intervalMinutes: intervalMinutes))
        checkpoint()
    }

    func recordSymptoms(_ severities: [Symptom: Int]) {
        stored.symptoms.append(SymptomEntry(date: .now, severities: severities))
        checkpoint()
    }

    func screenBecameActive() {
        guard activeSince == nil else { return }
        activeSince = .now
    }

    func screenBecameInactive() {
        guard activeSince != nil else { return }
        checkpoint()
        activeSince = nil
    }

    /// Moves screen time so far into `screenSeconds` and saves, so a kill loses little.
    func checkpoint() {
        if let activeSince {
            let now = Date.now
            addScreenTime(from: activeSince, to: now)
            self.activeSince = now
        }
        save()
    }

    /// The last `days` local days, oldest first, including today.
    func summaries(days: Int, now: Date = .now) -> [DaySummary] {
        let today = calendar.startOfDay(for: now)
        let ongoing = activeSince.map { now.timeIntervalSince($0) } ?? 0
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let rests = stored.rests.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let entries = stored.symptoms.filter { calendar.isDate($0.date, inSameDayAs: day) }
            var seconds = stored.screenSeconds[dayFormatter.string(from: day)] ?? 0
            if offset == 0 { seconds += ongoing }
            return DaySummary(
                day: day,
                completed: rests.filter { $0.outcome == .completed }.count,
                missed: rests.filter { $0.outcome != .completed }.count,
                screenHours: seconds / 3600,
                symptomScore: entries.isEmpty ? nil : Double(entries.map(\.score).reduce(0, +)) / Double(entries.count)
            )
        }
    }

    /// Splits the stretch at midnights so each day gets its own share.
    private func addScreenTime(from start: Date, to end: Date) {
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(nextDay, end)
            stored.screenSeconds[dayFormatter.string(from: dayStart), default: 0] += segmentEnd.timeIntervalSince(cursor)
            cursor = segmentEnd
        }
    }

    private func save() {
        prune()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save activity log: \(error, privacy: .public)")
        }
    }

    private func prune() {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: calendar.startOfDay(for: .now)) else { return }
        stored.rests.removeAll { $0.date < cutoff }
        stored.symptoms.removeAll { $0.date < cutoff }
        let cutoffKey = dayFormatter.string(from: cutoff)
        stored.screenSeconds = stored.screenSeconds.filter { $0.key >= cutoffKey }
    }
}

/// How symptom scores move with rest frequency, across days that have both.
struct RestSymptomCorrelation {
    static let minimumDays = 5

    let pairedDays: Int
    /// Pearson correlation of rests per hour against symptom score, from -1 to 1. Nil until there
    /// are `minimumDays` paired days, or when either value never varies.
    let coefficient: Double?
    /// The median rests per hour, which splits the days into more-rest and less-rest halves.
    let medianRate: Double?
    let scoreAtOrAboveMedian: Double?
    let scoreBelowMedian: Double?

    init(_ summaries: [DaySummary]) {
        let pairs = summaries.compactMap { day in
            day.restsPerHour.flatMap { rate in day.symptomScore.map { (rate: rate, score: $0) } }
        }
        pairedDays = pairs.count
        guard pairs.count >= Self.minimumDays else {
            coefficient = nil
            medianRate = nil
            scoreAtOrAboveMedian = nil
            scoreBelowMedian = nil
            return
        }

        let rates = pairs.map(\.rate)
        let scores = pairs.map(\.score)
        let meanRate = Self.mean(rates)!
        let meanScore = Self.mean(scores)!
        let covariance = zip(rates, scores).map { ($0 - meanRate) * ($1 - meanScore) }.reduce(0, +)
        let rateSpread = rates.map { pow($0 - meanRate, 2) }.reduce(0, +)
        let scoreSpread = scores.map { pow($0 - meanScore, 2) }.reduce(0, +)
        coefficient = rateSpread > 0 && scoreSpread > 0 ? covariance / (rateSpread * scoreSpread).squareRoot() : nil

        let sorted = rates.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        medianRate = median
        scoreAtOrAboveMedian = Self.mean(pairs.filter { $0.rate >= median }.map(\.score))
        scoreBelowMedian = Self.mean(pairs.filter { $0.rate < median }.map(\.score))
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
