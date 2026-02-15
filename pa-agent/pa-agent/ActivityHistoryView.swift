import SwiftUI

struct ActivityHistoryView: View {
    @ObservedObject var historyManager: ActivityHistoryManager
    @StateObject private var tokenUsageManager = TokenUsageManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    var body: some View {
        List {
            Section("AI Tokens (Today)") {
                let today = tokenUsageManager.summary(for: Date())
                let month = tokenUsageManager.monthlySummary(for: Date())
                let limit = tokenUsageManager.monthlyTokenLimit(hasActiveSubscription: subscriptionManager.hasActiveSubscription)
                let remaining = tokenUsageManager.remainingTokensThisMonth(hasActiveSubscription: subscriptionManager.hasActiveSubscription)

                HStack {
                    Text("Requests")
                    Spacer()
                    Text("\(today.requestCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Prompt Tokens")
                    Spacer()
                    Text("\(today.promptTokens)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Completion Tokens")
                    Spacer()
                    Text("\(today.completionTokens)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Total Tokens")
                    Spacer()
                    Text("\(today.totalTokens)")
                        .fontWeight(.semibold)
                }

                HStack {
                    Text("Monthly Limit")
                    Spacer()
                    Text("\(limit)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Used This Month")
                    Spacer()
                    Text("\(month.totalTokens)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Remaining This Month")
                    Spacer()
                    Text("\(remaining)")
                        .foregroundStyle(remaining > 0 ? Color.secondary : Color.orange)
                }

                if today.estimatedRequestCount > 0 {
                    Text("\(today.estimatedRequestCount) request(s) used estimated token counts because provider usage metrics were unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Daily Usage Report") {
                let dailyRows = tokenUsageManager.dailySummaries(limit: 14)
                if dailyRows.isEmpty {
                    Text("No AI token usage yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dailyRows) { day in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.dayStart.formatted(date: .abbreviated, time: .omitted))
                                    .font(.subheadline)
                                Text("Requests: \(day.requestCount) • Success: \(day.successfulRequestCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(day.totalTokens)")
                                .font(.headline)
                        }
                    }
                }
            }

            Section("Monthly Usage Report") {
                let monthlyRows = tokenUsageManager.monthlySummaries(limit: 12)
                if monthlyRows.isEmpty {
                    Text("No AI token usage yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monthlyRows) { month in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(month.monthStart.formatted(.dateTime.year().month(.abbreviated)))
                                    .font(.subheadline)
                                Text("Requests: \(month.requestCount) • Success: \(month.successfulRequestCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(month.totalTokens)")
                                .font(.headline)
                        }
                    }
                }
            }

            Section("Activity History") {
                ForEach(historyManager.history) { log in
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: iconForType(log.actionType))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .foregroundStyle(.blue)
                            Text(log.actionType.capitalized)
                                .font(.headline)
                            Spacer()
                            Text(log.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(log.description)
                            .font(.body)
                    }
                }
                .onDelete { indexSet in
                    historyManager.delete(at: indexSet)
                }
            }
        }
        .navigationTitle("Activity History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear All") {
                    historyManager.clearHistory()
                }
            }
        }
    }
    
    func iconForType(_ type: String) -> String {
        switch type.lowercased() {
        case "call": return "phone.fill"
        case "message": return "message.fill"
        case "email": return "envelope.fill"
        case "task": return "checkmark.circle.fill"
        case "greeting": return "hand.wave.fill"
        default: return "clock"
        }
    }
}
