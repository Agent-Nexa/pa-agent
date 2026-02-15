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

final class TokenUsageManager: ObservableObject {
    static let shared = TokenUsageManager()

    @Published private(set) var entries: [TokenUsageEntry] = []

    private let storageKey = "AI_TOKEN_USAGE_ENTRIES"
    private let calendar = Calendar.current

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
            self.save()
        }
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func summary(for date: Date) -> DailyTokenUsage {
        let dayStart = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let rows = entries.filter { $0.date >= dayStart && $0.date < nextDay }
        return buildSummary(for: dayStart, rows: rows)
    }

    func dailySummaries(limit: Int = 14) -> [DailyTokenUsage] {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        let sortedDays = grouped.keys.sorted(by: >).prefix(max(limit, 1))
        return sortedDays.map { day in
            let rows = grouped[day] ?? []
            return buildSummary(for: day, rows: rows)
        }
    }

    func dailyTokenLimit(hasActiveSubscription: Bool) -> Int {
        hasActiveSubscription ? 200_000 : 20_000
    }

    func remainingTokensToday(hasActiveSubscription: Bool) -> Int {
        let limit = dailyTokenLimit(hasActiveSubscription: hasActiveSubscription)
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
    }
}
