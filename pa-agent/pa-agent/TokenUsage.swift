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

// MARK: - Server stats models

struct TokenServerPeriodStats {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let successCount: Int
}

struct TokenServerDailyStat: Identifiable {
    let date: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let successCount: Int
    var id: Date { date }
}

struct TokenServerMonthlyStat: Identifiable {
    let monthStart: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let successCount: Int
    var id: Date { monthStart }
}

struct TokenServerStats {
    let today: TokenServerPeriodStats
    let currentMonth: TokenServerPeriodStats
    let daily: [TokenServerDailyStat]
    let monthly: [TokenServerMonthlyStat]
}

// MARK: - TokenUsageManager

final class TokenUsageManager: ObservableObject {
    static let shared = TokenUsageManager()

    @Published private(set) var entries: [TokenUsageEntry] = []

    /// Set this to the signed-in user's email as soon as auth completes.
    /// Every subsequent addEntry call will fire a background server log.
    var currentUserId: String = ""

    private var serverBaseURL: String {
        UserDefaults.standard.string(forKey: "PA_AGENT_SERVER_URL")
            ?? "https://pa-agent-web-frontend.agreeableisland-6e08f0fa.australiaeast.azurecontainerapps.io"
    }

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

        // Insert synchronously when already on the main thread so that callers
        // reading `entries` immediately after addEntry see the new value.
        if Thread.isMainThread {
            entries.insert(entry, at: 0)
            trimEntriesIfNeeded()
            save()
        } else {
            DispatchQueue.main.async {
                self.entries.insert(entry, at: 0)
                self.trimEntriesIfNeeded()
                self.save()
            }
        }

        // Fire-and-forget server log — never blocks the UI.
        if !currentUserId.isEmpty {
            let userId = currentUserId
            Task.detached(priority: .utility) { [weak self] in
                await self?.logToServer(entry, userId: userId)
            }
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
        // testflight override: high limit for testing
        if Bundle.main.isTestFlight { return 99_999_999 }
        return hasActiveSubscription ? 200_000 : 20_000
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

    // MARK: - Server logging

    private func logToServer(_ entry: TokenUsageEntry, userId: String) async {
        guard let url = URL(string: "\(serverBaseURL)/api/token-transactions") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "user_id":           userId,
            "feature":           entry.feature,
            "provider":          entry.provider,
            "model":             entry.model,
            "prompt_tokens":     entry.promptTokens,
            "completion_tokens": entry.completionTokens,
            "total_tokens":      entry.totalTokens,
            "success":           entry.success,
            "error_reason":      entry.errorReason as Any,
            "is_estimated":      entry.isEstimated,
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("[TokenUsageManager] ⚠️  Server log returned \(http.statusCode)")
            }
        } catch {
            print("[TokenUsageManager] ⚠️  Server log failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Fetch server stats

    func fetchServerStats(userId: String, days: Int = 14, months: Int = 12) async -> TokenServerStats? {
        guard !userId.isEmpty,
              let url = URL(string: "\(serverBaseURL)/api/token-transactions/\(userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId)/stats?days=\(days)&months=\(months)")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            func parsePeriod(_ d: [String: Any]?) -> TokenServerPeriodStats {
                guard let d else { return TokenServerPeriodStats(promptTokens: 0, completionTokens: 0, totalTokens: 0, requestCount: 0, successCount: 0) }
                return TokenServerPeriodStats(
                    promptTokens:     d["prompt_tokens"]     as? Int ?? 0,
                    completionTokens: d["completion_tokens"] as? Int ?? 0,
                    totalTokens:      d["total_tokens"]      as? Int ?? 0,
                    requestCount:     d["request_count"]     as? Int ?? 0,
                    successCount:     d["success_count"]     as? Int ?? 0
                )
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")

            let monthFormatter = DateFormatter()
            monthFormatter.dateFormat = "yyyy-MM"
            monthFormatter.timeZone = TimeZone(identifier: "UTC")

            let dailyArr = (json["daily"] as? [[String: Any]] ?? []).compactMap { d -> TokenServerDailyStat? in
                guard let dateStr = d["date"] as? String,
                      let date = formatter.date(from: dateStr) else { return nil }
                return TokenServerDailyStat(
                    date:             date,
                    promptTokens:     d["prompt_tokens"]     as? Int ?? 0,
                    completionTokens: d["completion_tokens"] as? Int ?? 0,
                    totalTokens:      d["total_tokens"]      as? Int ?? 0,
                    requestCount:     d["request_count"]     as? Int ?? 0,
                    successCount:     d["success_count"]     as? Int ?? 0
                )
            }

            let monthlyArr = (json["monthly"] as? [[String: Any]] ?? []).compactMap { d -> TokenServerMonthlyStat? in
                guard let monthStr = d["month"] as? String,
                      let date = monthFormatter.date(from: monthStr) else { return nil }
                return TokenServerMonthlyStat(
                    monthStart:       date,
                    promptTokens:     d["prompt_tokens"]     as? Int ?? 0,
                    completionTokens: d["completion_tokens"] as? Int ?? 0,
                    totalTokens:      d["total_tokens"]      as? Int ?? 0,
                    requestCount:     d["request_count"]     as? Int ?? 0,
                    successCount:     d["success_count"]     as? Int ?? 0
                )
            }

            return TokenServerStats(
                today:        parsePeriod(json["today"]         as? [String: Any]),
                currentMonth: parsePeriod(json["current_month"] as? [String: Any]),
                daily:        dailyArr,
                monthly:      monthlyArr
            )
        } catch {
            print("[TokenUsageManager] ⚠️  fetchServerStats failed (\(error.localizedDescription))")
            return nil
        }
    }

    // MARK: - Summaries

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
