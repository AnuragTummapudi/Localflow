import SwiftUI
import Shared

// MARK: - Insights Pane

/// The Insights settings pane — local-only analytics derived from DictationHistoryStore.
public struct InsightsPane: View {
    @ObservedObject public var store: DictationHistoryStore

    private var stats: InsightsStats { InsightsStats(items: store.items) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    LFPaneTitle("Insights")
                        .padding(.top, 8)
                    Text("Calculated entirely on this Mac.")
                        .font(LocalFlowDesign.fragmentMono(size: 11))
                        .foregroundStyle(LocalFlowDesign.graphite)
                }
                .padding(.top, 16)

                // ── Stat cards ───────────────────────────────────────────
                HStack(spacing: 12) {
                    StatCard(label: "Total Words", value: "\(stats.totalWords)")
                    StatCard(label: "Avg WPM", value: stats.avgWPM > 0 ? "\(stats.avgWPM)" : "—")
                    StatCard(label: "Current Streak", value: "\(stats.currentStreak)d")
                    StatCard(label: "Longest Streak", value: "\(stats.longestStreak)d")
                }

                // ── Streak heatmap ───────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "Activity", subtitle: "Your last 52 weeks of dictation")
                    StreakHeatmap(items: store.items, longestStreak: stats.longestStreak, currentStreak: stats.currentStreak)
                }

                // ── App usage breakdown ──────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "Where you write", subtitle: "Words inserted by app")
                    AppUsageBreakdown(items: store.items)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .background(LocalFlowDesign.canvas)
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title).font(LocalFlowDesign.instrumentSerif(size: 22)).foregroundStyle(LocalFlowDesign.ink)
            Text(subtitle).font(LocalFlowDesign.generalSans(size: 12)).foregroundStyle(LocalFlowDesign.graphite)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Stats model

private struct InsightsStats {
    let totalWords: Int
    let avgWPM: Int
    let currentStreak: Int
    let longestStreak: Int

    init(items: [DictationHistoryItem]) {
        totalWords = items.reduce(0) { $0 + $1.text.split(separator: " ").count }

        if items.isEmpty {
            avgWPM = 0
        } else {
            let wcs = items.map { $0.text.split(separator: " ").count }
            let nonEmpty = wcs.filter { $0 > 0 }
            let meanWords = nonEmpty.reduce(0, +) / max(1, nonEmpty.count)
            avgWPM = min(220, meanWords * 3)
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let activeDays = Set(items.map { cal.startOfDay(for: $0.createdAt) })

        var cur = 0
        var cursor = today
        while activeDays.contains(cursor) {
            cur += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        currentStreak = cur

        // Guard against empty ranges — `1..<0` is a fatal trap.
        let sorted = activeDays.sorted()
        var longest = 0
        var run = 0
        var previousDay: Date?
        for day in sorted {
            if let previousDay,
               cal.dateComponents([.day], from: previousDay, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previousDay = day
        }
        longestStreak = longest
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(value)
                .font(LocalFlowDesign.instrumentSerif(size: 34))
                .foregroundStyle(LocalFlowDesign.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label.uppercased())
                .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(LocalFlowDesign.graphite)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(LocalFlowDesign.cardBackground(cornerRadius: 16))
    }
}

// MARK: - Streak heatmap (GitHub-style contribution grid)

private struct StreakHeatmap: View {
    let items: [DictationHistoryItem]
    let longestStreak: Int
    let currentStreak: Int

    private let daysPerWeek = 7
    private let weeks = 52
    private let cellSize: CGFloat = 13
    private let gap: CGFloat = 3

    private var countByDay: [Date: Int] {
        let cal = Calendar.current
        var dict: [Date: Int] = [:]
        for item in items {
            let day = cal.startOfDay(for: item.createdAt)
            dict[day, default: 0] += 1
        }
        return dict
    }

    /// Week columns × day rows, Monday-aligned, covering a full 52 weeks.
    private var grid: [[Date]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = (cal.component(.weekday, from: today) + 5) % 7 // 0 = Mon
        let startOfThisWeek = cal.date(byAdding: .day, value: -weekday, to: today)!
        let firstDay = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: startOfThisWeek)!

        return (0..<weeks).map { week in
            (0..<daysPerWeek).map { day in
                cal.date(byAdding: .day, value: week * 7 + day, to: firstDay)!
            }
        }
    }

    private func fillColor(for count: Int) -> Color {
        switch count {
        case 0: return LocalFlowDesign.graphite.opacity(0.12)
        case 1: return LocalFlowDesign.signal.opacity(0.28)
        case 2...3: return LocalFlowDesign.signal.opacity(0.52)
        case 4...6: return LocalFlowDesign.signal.opacity(0.78)
        default: return LocalFlowDesign.signal
        }
    }

    private let dayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]

    var body: some View {
        let counts = countByDay
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentStreak == 1 ? "1 day in a row" : "\(currentStreak) days in a row")
                        .font(LocalFlowDesign.generalSans(size: 15, weight: .medium)).foregroundStyle(LocalFlowDesign.ink)
                    Text("Keep your writing momentum going.")
                        .font(LocalFlowDesign.generalSans(size: 12)).foregroundStyle(LocalFlowDesign.graphite)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("LONGEST STREAK").font(LocalFlowDesign.fragmentMono(size: 9)).foregroundStyle(LocalFlowDesign.graphite)
                    Text("\(longestStreak) days").font(LocalFlowDesign.generalSans(size: 14, weight: .medium)).foregroundStyle(LocalFlowDesign.ink)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: gap) {
                    Color.clear.frame(height: 16)
                    ForEach(0..<daysPerWeek, id: \.self) { d in
                        Text(dayLabels[d])
                            .font(LocalFlowDesign.fragmentMono(size: 9))
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .frame(width: 28, height: cellSize, alignment: .trailing)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    monthLabelsRow
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<weeks, id: \.self) { week in
                            VStack(spacing: gap) {
                                ForEach(0..<daysPerWeek, id: \.self) { day in
                                    let date = grid[week][day]
                                    let count = counts[date] ?? 0
                                    let isFuture = date > today
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .fill(isFuture ? Color.clear : fillColor(for: count))
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(LocalFlowDesign.hairline.opacity(count == 0 ? 0.3 : 0), lineWidth: 0.5))
                                        .frame(width: cellSize, height: cellSize)
                                        .accessibilityLabel(isFuture ? "Future day" : "\(date.formatted(date: .abbreviated, time: .omitted)): \(count) dictation\(count == 1 ? "" : "s")")
                                        .help(isFuture ? "" : "\(date.formatted(date: .abbreviated, time: .omitted)): \(count) dictation\(count == 1 ? "" : "s")")
                                }
                            }
                        }
                    }
                }
            }
            }

            HStack(spacing: 6) {
                Text("Less")
                    .font(LocalFlowDesign.generalSans(size: 10))
                    .foregroundStyle(LocalFlowDesign.graphite)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fillColor(for: step == 0 ? 0 : (step == 1 ? 1 : (step == 2 ? 3 : (step == 3 ? 5 : 8)))))
                        .frame(width: 10, height: 10)
                }
                Text("More")
                    .font(LocalFlowDesign.generalSans(size: 10))
                    .foregroundStyle(LocalFlowDesign.graphite)
            }
        }
        .padding(20)
        .background(LocalFlowDesign.cardBackground(cornerRadius: 16))
    }

    private var monthLabelsRow: some View {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        return HStack(spacing: gap) {
            ForEach(0..<weeks, id: \.self) { week in
                let date = grid[week][0]
                let show: Bool = {
                    if week == 0 { return true }
                    let prev = grid[week - 1][0]
                    return cal.component(.month, from: date) != cal.component(.month, from: prev)
                }()
                Color.clear
                    .frame(width: cellSize, height: 14)
                    .overlay(alignment: .leading) {
                        if show {
                            Text(fmt.string(from: date))
                                .font(LocalFlowDesign.fragmentMono(size: 9))
                                .foregroundStyle(LocalFlowDesign.graphite)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
            }
        }
    }
}

// MARK: - App usage breakdown

private struct AppUsageBreakdown: View {
    let items: [DictationHistoryItem]

    private struct AppEntry: Identifiable {
        let id: String
        let displayName: String
        let wordCount: Int
        let sessionCount: Int
    }

    private var entries: [AppEntry] {
        var byApp: [String: (words: Int, sessions: Int)] = [:]
        for item in items {
            let key = item.bundleIdentifier ?? "unknown"
            let name = Self.displayName(for: key)
            let wc = item.text.split(separator: " ").count
            let existing = byApp[name] ?? (words: 0, sessions: 0)
            byApp[name] = (words: existing.words + wc, sessions: existing.sessions + 1)
        }
        return byApp
            .sorted { $0.value.words > $1.value.words }
            .prefix(8)
            .map { name, val in
                AppEntry(
                    id: name,
                    displayName: name,
                    wordCount: val.words,
                    sessionCount: val.sessions
                )
            }
    }

    private static var nameCache: [String: String] = [:]

    private static func displayName(for bundleID: String) -> String {
        if let cached = nameCache[bundleID] {
            return cached
        }

        let known: [String: String] = [
            "com.todesktop.230313mzl4w4u92": "Cursor",
            "com.google.antigravity-ide": "Antigravity",
            "com.microsoft.VSCode": "VS Code",
            "company.thebrowser.dia": "Dia",
            "company.thebrowser.Browser": "Arc",
            "net.whatsapp.WhatsApp": "WhatsApp",
            "com.apple.mail": "Mail",
            "com.apple.Notes": "Notes",
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Chrome",
            "com.microsoft.Word": "Word",
            "com.microsoft.Outlook": "Outlook",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.figma.Desktop": "Figma",
            "com.notion.id": "Notion",
            "com.apple.dt.Xcode": "Xcode",
            "com.apple.finder": "Finder",
            "unknown": "Unknown App"
        ]
        if let name = known[bundleID] {
            nameCache[bundleID] = name
            return name
        }

        // 1. Check currently running applications
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName, !name.isEmpty {
            nameCache[bundleID] = name
            return name
        }

        // 2. Query LaunchServices for installed application bundle metadata
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            if let bundle = Bundle(url: url) {
                if let disp = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !disp.isEmpty {
                    nameCache[bundleID] = disp
                    return disp
                }
                if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                    nameCache[bundleID] = name
                    return name
                }
            }
            let fileDisplayName = FileManager.default.displayName(atPath: url.path)
            if !fileDisplayName.isEmpty && fileDisplayName != url.lastPathComponent {
                nameCache[bundleID] = fileDisplayName
                return fileDisplayName
            }
            let cleanName = url.deletingPathExtension().lastPathComponent
            if !cleanName.isEmpty {
                nameCache[bundleID] = cleanName
                return cleanName
            }
        }

        // 3. Fallback: humanize bundle ID (avoiding raw alphanumeric hashes like 230313mzl4w4u92)
        let parts = bundleID.split(separator: ".")
        if let last = parts.last, last.count > 2 && !last.allSatisfy({ $0.isNumber }) {
            let hasManyDigits = last.filter({ $0.isNumber }).count >= 4
            if hasManyDigits && parts.count >= 2 {
                let prior = parts[parts.count - 2]
                if prior.count > 2 {
                    let resolved = String(prior).capitalized
                    nameCache[bundleID] = resolved
                    return resolved
                }
            }
            let resolved = String(last).capitalized
            nameCache[bundleID] = resolved
            return resolved
        }

        nameCache[bundleID] = bundleID
        return bundleID
    }

    var body: some View {
        if entries.isEmpty {
            Text("No app usage data yet — dictate in any app to see it here.")
                .font(LocalFlowDesign.generalSans(size: 13))
                .foregroundStyle(LocalFlowDesign.graphite)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LocalFlowDesign.cardBackground(cornerRadius: 16))
        } else {
            let maxWords = max(1, entries.first?.wordCount ?? 1)
            VStack(spacing: 12) {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Text(entry.displayName.uppercased())
                            .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                            .tracking(0.6)
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)

                        GeometryReader { geo in
                            let ratio = CGFloat(entry.wordCount) / CGFloat(maxWords)
                            let barWidth = geo.size.width * min(1, max(0, ratio))
                            ZStack(alignment: .leading) {
                                Capsule().fill(LocalFlowDesign.graphite.opacity(0.12))
                                Capsule()
                                    .fill(LocalFlowDesign.signal)
                                    .frame(width: max(6, barWidth.isFinite ? barWidth : 6))
                            }
                        }
                        .frame(height: 8)

                        Text("\(entry.wordCount)")
                            .font(LocalFlowDesign.fragmentMono(size: 11))
                            .foregroundStyle(LocalFlowDesign.ink)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .background(LocalFlowDesign.cardBackground(cornerRadius: 16))
        }
    }
}
