//
//  EmailStore.swift
//  pa-agent
//
//  Observable store that merges Gmail and Outlook into a single sorted list.
//  Persists to UserDefaults (JSON encoded, capped at 500 items).
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class EmailStore: ObservableObject {

    static let shared = EmailStore()
    private init() { load() }

    private let udKey    = "nexaUnifiedEmails"
    private let maxStore = 500

    // ── Published ──────────────────────────────────────────────────────
    @Published private(set) var emails: [UnifiedEmail] = []
    @Published var isRefreshing: Bool = false
    @Published var lastRefreshed: Date?
    @Published var lastError: String?

    /// Highest-priority unread emails first — used for agent context injection.
    var priorityQueue: [UnifiedEmail] {
        emails.filter { !$0.isRead }
             .sorted { ($0.priority.sortOrder, $0.date) < ($1.priority.sortOrder, $1.date) }
    }

    // ── Refresh ────────────────────────────────────────────────────────

    func refresh() async {
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false; lastRefreshed = Date() }

        let mgr = EmailAccountsManager.shared
        var combined: [UnifiedEmail] = []
        var errors: [String] = []

        for account in mgr.accounts {
            do {
                switch account.provider {
                case .gmail:
                    let threadIds = try await mgr.gmailFetchThreadList(account: account, maxResults: 20)
                    for tid in threadIds.prefix(20) {
                        let msgs = try await mgr.gmailFetchThread(account: account, threadId: tid)
                        combined.append(contentsOf: msgs)
                    }
                case .outlook:
                    let msgs = try await mgr.outlookFetchInbox(account: account, maxResults: 20)
                    combined.append(contentsOf: msgs)
                }
            } catch {
                errors.append("\(account.email): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty { lastError = errors.joined(separator: " | ") }

        if !combined.isEmpty {
            // Merge with existing — preserve AI fields already set
            var existing = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
            for var e in combined {
                if let prev = existing[e.id] {
                    e.aiSummary        = prev.aiSummary
                    e.aiPriorityReason = prev.aiPriorityReason
                    e.priority         = prev.priority
                }
                existing[e.id] = e
            }
            emails = Array(existing.values)
                .sorted { $0.date > $1.date }
                .prefix(maxStore)
                .map { $0 }
            save()
        }
    }

    // ── Mutations ──────────────────────────────────────────────────────

    func markRead(id: String) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].isRead = true
        save()
        let email = emails[idx]
        Task {
            let mgr = EmailAccountsManager.shared
            // Prefer account-scoped routing via accountId
            if let accountId = email.accountId,
               let account = mgr.accounts.first(where: { $0.id == accountId }) {
                if email.provider == .gmail {
                    try? await mgr.gmailModifyLabels(account: account, messageId: id, remove: ["UNREAD"])
                } else {
                    try? await mgr.outlookMarkRead(account: account, messageId: id)
                }
            } else {
                // Legacy fallback to singletons
                if email.provider == .gmail {
                    try? await GmailService.shared.modifyLabels(messageId: id, remove: ["UNREAD"])
                } else {
                    try? await OutlookService.shared.markRead(messageId: id)
                }
            }
        }
    }

    func flagEmail(id: String) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].isFlagged.toggle()
        save()
    }

    func updatePriority(id: String, priority: EmailPriority, reason: String? = nil, summary: String? = nil) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].priority = priority
        if let r = reason  { emails[idx].aiPriorityReason = r }
        if let s = summary { emails[idx].aiSummary = s }
        save()
    }

    func thread(for email: UnifiedEmail) -> [UnifiedEmail] {
        emails.filter { $0.threadId == email.threadId && $0.provider == email.provider }
              .sorted { $0.date < $1.date }
    }

    // ── Persistence ────────────────────────────────────────────────────

    private func save() {
        guard let data = try? JSONEncoder().encode(emails) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([UnifiedEmail].self, from: data) else { return }
        emails = decoded
    }
}
