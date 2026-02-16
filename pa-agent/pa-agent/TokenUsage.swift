import Foundation
import SwiftUI
import Combine

struct TokenUsageEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let feature: String
    let provider: String
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let success: Bool
    let errorReason: String?
    let isEstimated: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        feature: String,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        success: Bool,
        errorReason: String?,
        isEstimated: Bool
    ) {
        self.id = id
        self.date = date
        self.feature = feature
        self.provider = provider
        self.model = model
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.totalTokens = max(0, totalTokens)
        self.success = success
        self.errorReason = errorReason
        self.isEstimated = isEstimated
    }
}

struct DailyTokenUsage: Identifiable {
    let dayStart: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let successfulRequestCount: Int
    let estimatedRequestCount: Int

    var id: Date { dayStart }
}

struct MonthlyTokenUsage: Identifiable {
    let monthStart: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let successfulRequestCount: Int
    let estimatedRequestCount: Int

    var id: Date { monthStart }
}

final class TokenUsageManager: ObservableObject {
    static let shared = TokenUsageManager()

    @Published private(set) var entries: [TokenUsageEntry] = []

    private let storageKey = "AI_TOKEN_USAGE_ENTRIES"
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = .autoupdatingCurrent
        value.timeZone = .autoupdatingCurrent
        return value
    }
    private let maxStoredEntries = 3000

    private init() {
        load()
    }

    func addEntry(
        feature: String,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        success: Bool,
        errorReason: String? = nil,
        isEstimated: Bool = false
    ) {
        let total = max(0, promptTokens) + max(0, completionTokens)
        let entry = TokenUsageEntry(
            feature: feature,
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: total,
            success: success,
            errorReason: errorReason,
            isEstimated: isEstimated
        )

        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            self.trimEntriesIfNeeded()
            self.save()
        }
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func summary(for date: Date) -> DailyTokenUsage {
        let dayStart = calendar.startOfDay(for: date)
        let rows = entries(inSameDayAs: dayStart)
        return buildSummary(for: dayStart, rows: rows)
    }

    func dailySummaries(limit: Int = 14) -> [DailyTokenUsage] {
        let grouped = Dictionary(grouping: entries) { entry in
            dayBucket(for: entry.date)
        }
        let sortedBuckets = grouped.keys.sorted(by: >).prefix(max(limit, 1))
        return sortedBuckets.compactMap { bucket in
            guard let day = dayStart(for: bucket) else { return nil }
            let rows = grouped[bucket] ?? []
            return buildSummary(for: day, rows: rows)
        }
    }

    func monthlySummaries(limit: Int = 12) -> [MonthlyTokenUsage] {
        let grouped = Dictionary(grouping: entries) { entry in
            monthBucket(for: entry.date)
        }
        let sortedBuckets = grouped.keys.sorted(by: >).prefix(max(limit, 1))
        return sortedBuckets.compactMap { bucket in
            guard let month = monthStart(for: bucket) else { return nil }
            let rows = grouped[bucket] ?? []
            return buildMonthlySummary(for: month, rows: rows)
        }
    }

    func monthlySummary(for date: Date) -> MonthlyTokenUsage {
        let month = monthStart(for: date)
        let rows = entries(inSameMonthAs: month)
        return buildMonthlySummary(for: month, rows: rows)
    }

    func monthlyTokenLimit(hasActiveSubscription: Bool) -> Int {
        hasActiveSubscription ? 200_000 : 20_000
    }

    func remainingTokensThisMonth(hasActiveSubscription: Bool) -> Int {
        let limit = monthlyTokenLimit(hasActiveSubscription: hasActiveSubscription)
        let monthTotal = monthlySummary(for: Date()).totalTokens
        return max(0, limit - monthTotal)
    }

    func dailyTokenLimit(hasActiveSubscription: Bool) -> Int {
        monthlyTokenLimit(hasActiveSubscription: hasActiveSubscription)
    }

    func remainingTokensToday(hasActiveSubscription: Bool) -> Int {
        let limit = monthlyTokenLimit(hasActiveSubscription: hasActiveSubscription)
        let today = summary(for: Date()).totalTokens
        return max(0, limit - today)
    }

    private func buildSummary(for dayStart: Date, rows: [TokenUsageEntry]) -> DailyTokenUsage {
        let prompt = rows.reduce(0) { $0 + $1.promptTokens }
        let completion = rows.reduce(0) { $0 + $1.completionTokens }
        let total = rows.reduce(0) { $0 + $1.totalTokens }
        let requestCount = rows.count
        let successfulRequestCount = rows.filter(\.success).count
        let estimatedRequestCount = rows.filter(\.isEstimated).count

        return DailyTokenUsage(
            dayStart: dayStart,
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            requestCount: requestCount,
            successfulRequestCount: successfulRequestCount,
            estimatedRequestCount: estimatedRequestCount
        )
    }

    private func monthStart(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    private struct DayBucket: Hashable, Comparable {
        let year: Int
        let month: Int
        let day: Int

        static func < (lhs: DayBucket, rhs: DayBucket) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            if lhs.month != rhs.month { return lhs.month < rhs.month }
            return lhs.day < rhs.day
        }
    }

    private struct MonthBucket: Hashable, Comparable {
        let year: Int
        let month: Int

        static func < (lhs: MonthBucket, rhs: MonthBucket) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            return lhs.month < rhs.month
        }
    }

    private func dayBucket(for date: Date) -> DayBucket {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DayBucket(
            year: components.year ?? 0,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    private func monthBucket(for date: Date) -> MonthBucket {
        let components = calendar.dateComponents([.year, .month], from: date)
        return MonthBucket(
            year: components.year ?? 0,
            month: components.month ?? 1
        )
    }

    private func dayStart(for bucket: DayBucket) -> Date? {
        calendar.date(from: DateComponents(year: bucket.year, month: bucket.month, day: bucket.day))
    }

    private func monthStart(for bucket: MonthBucket) -> Date? {
        calendar.date(from: DateComponents(year: bucket.year, month: bucket.month, day: 1))
    }

    private func entries(inSameDayAs day: Date) -> [TokenUsageEntry] {
        let dayStart = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return entries.filter { calendar.isDate($0.date, inSameDayAs: dayStart) }
        }
        return entries.filter { $0.date >= dayStart && $0.date < nextDay }
    }

    private func entries(inSameMonthAs date: Date) -> [TokenUsageEntry] {
        let month = monthStart(for: date)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) else {
            let components = calendar.dateComponents([.year, .month], from: month)
            return entries.filter {
                let rowComponents = calendar.dateComponents([.year, .month], from: $0.date)
                return rowComponents.year == components.year && rowComponents.month == components.month
            }
        }
        return entries.filter { $0.date >= month && $0.date < nextMonth }
    }

    private func buildMonthlySummary(for monthStart: Date, rows: [TokenUsageEntry]) -> MonthlyTokenUsage {
        let prompt = rows.reduce(0) { $0 + $1.promptTokens }
        let completion = rows.reduce(0) { $0 + $1.completionTokens }
        let total = rows.reduce(0) { $0 + $1.totalTokens }
        let requestCount = rows.count
        let successfulRequestCount = rows.filter(\.success).count
        let estimatedRequestCount = rows.filter(\.isEstimated).count

        return MonthlyTokenUsage(
            monthStart: monthStart,
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            requestCount: requestCount,
            successfulRequestCount: successfulRequestCount,
            estimatedRequestCount: estimatedRequestCount
        )
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TokenUsageEntry].self, from: data)
        else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.date > $1.date }
        trimEntriesIfNeeded()
    }

    private func trimEntriesIfNeeded() {
        guard entries.count > maxStoredEntries else { return }
        entries = Array(entries.prefix(maxStoredEntries))
    }
}
