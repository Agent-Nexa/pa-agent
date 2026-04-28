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

    // ── Triage state ───────────────────────────────────────────────────
    @Published var isTriaging:     Bool    = false
    @Published var triageProgress: String? = nil
    @Published var triageError:    String? = nil
    private(set) var lastTriageDate: Date? = nil

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
        // Snapshot both on main before leaving the actor
        let snapshot = emails
        let accounts = mgr.accounts

        // All fetching + merge + sort runs off-main — never blocks UIKit
        let (merged, errs): ([UnifiedEmail], [String]) = await Task.detached(priority: .utility) {
            var combined: [UnifiedEmail] = []
            var errors:   [String] = []

            for account in accounts {
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

            guard !combined.isEmpty else { return ([], errors) }

            // Merge: preserve AI/triage fields from snapshot
            var dict = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
            for var e in combined {
                if let prev = dict[e.id] {
                    e.aiSummary        = prev.aiSummary
                    e.aiPriorityReason = prev.aiPriorityReason
                    e.priority         = prev.priority
                    e.isTriaged        = prev.isTriaged
                    e.isActionRequired = prev.isActionRequired
                    e.requiresReply    = prev.requiresReply
                    e.requiresMeeting  = prev.requiresMeeting
                    e.aiDraftBody      = prev.aiDraftBody
                    e.isReplied        = prev.isReplied
                    e.scheduledEvents  = prev.scheduledEvents
                    // Once replied, never revert reply-related flags on refresh
                    if prev.isReplied {
                        e.requiresReply    = false
                        e.isActionRequired = false
                    }
                }
                dict[e.id] = e
            }
            let sorted = Array(dict.values)
                .sorted { $0.date > $1.date }
                .prefix(500)
                .map { $0 }
            return (sorted, errors)
        }.value

        // Single @Published write on main — one SwiftUI diff
        if !errs.isEmpty { lastError = errs.joined(separator: " | ") }
        if !merged.isEmpty { emails = merged; save() }
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

    func setActionRequired(ids: Set<String>) {
        var changed = false
        for i in emails.indices {
            let shouldFlag = ids.contains(emails[i].id)
            if emails[i].isActionRequired != shouldFlag {
                emails[i].isActionRequired = shouldFlag
                changed = true
            }
        }
        if changed { save() }
    }

    func clearActionFlag(id: String) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].isActionRequired = false
        save()
    }

    /// Mark an email as having been triaged (so it won't be re-evaluated on next run)
    /// and optionally set whether it needs action.
    func markTriaged(id: String, isActionRequired: Bool, requiresReply: Bool = false, draftBody: String? = nil) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].isTriaged = true
        emails[idx].isActionRequired = isActionRequired
        emails[idx].requiresReply = requiresReply
        if let d = draftBody { emails[idx].aiDraftBody = d }
        // Archiving (isActionRequired = false) must also clear isReplied so the
        // email is removed from actionRequiredEmails (which includes isReplied emails)
        if !isActionRequired { emails[idx].isReplied = false }
        save()
    }

    /// Silent batch-apply triage results — used by the background monitor.
    /// Never touches isTriaging / triageProgress, so the UI is not disturbed.
    func applyTriageResults(_ results: [(id: String, actionable: Bool, requiresReply: Bool, requiresMeeting: Bool, draftBody: String?)]) {
        guard !results.isEmpty else { return }
        for r in results {
            guard let idx = emails.firstIndex(where: { $0.id == r.id }) else { continue }
            // Don't override emails the user has already explicitly triaged/archived
            guard !emails[idx].isTriaged else { continue }
            emails[idx].isTriaged        = true
            emails[idx].isActionRequired = r.actionable
            emails[idx].requiresReply    = r.requiresReply
            emails[idx].requiresMeeting  = r.requiresMeeting
            if let d = r.draftBody { emails[idx].aiDraftBody = d }
        }
        save()
    }

    /// Mark an email as replied — removes it from the triage action queue.
    func markReplied(id: String, sentBody: String? = nil) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].isReplied        = true
        emails[idx].isActionRequired = false
        emails[idx].requiresReply    = false   // prevent stale "Review Reply" chip after refresh
        emails[idx].isTriaged        = true
        // Persist the actual sent body so EmailThreadView can show what was replied
        if let body = sentBody, !body.isEmpty {
            emails[idx].aiDraftBody = body
        }
        save()
    }

    // MARK: - Scheduled-events (inline Schedule chip)

    /// Append newly scheduled events to an email (keeps existing events).
    func addScheduledEvents(id: String, events: [ScheduledEmailEvent]) {
        guard !events.isEmpty,
              let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].scheduledEvents.append(contentsOf: events)
        save()
    }

    /// Remove a single scheduled event badge (and its corresponding task was already deleted).
    func removeScheduledEvent(emailId: String, taskId: UUID) {
        guard let idx = emails.firstIndex(where: { $0.id == emailId }) else { return }
        emails[idx].scheduledEvents.removeAll { $0.taskId == taskId }
        save()
    }

    /// Remove all scheduled event badges from an email (e.g. before re-scheduling).
    func clearScheduledEvents(id: String) {
        guard let idx = emails.firstIndex(where: { $0.id == id }) else { return }
        emails[idx].scheduledEvents.removeAll()
        save()
    }

    var actionRequiredEmails: [UnifiedEmail] {
        // Keep replied emails visible so the user can review what was sent
        emails.filter { $0.isActionRequired || $0.isReplied }.sorted { $0.date > $1.date }
    }

    func thread(for email: UnifiedEmail) -> [UnifiedEmail] {
        emails.filter { $0.threadId == email.threadId && $0.provider == email.provider }
              .sorted { $0.date < $1.date }
    }

    // ── Triage engine ─────────────────────────────────────────────────

    private struct TriageResult {
        let id: String
        let actionable: Bool
        let requiresReply: Bool
        let requiresMeeting: Bool
        let draftBody: String?
    }

    func runTriage(ep: String, key: String, mdl: String, azure: Bool, token: String) async {
        guard !isTriaging else { return }
        isTriaging = true
        triageError = nil
        triageProgress = nil

        await refresh()
        if let err = lastError { triageError = err }

        let unread = emails.filter { !$0.isRead && !$0.isTriaged }
        guard !unread.isEmpty else { isTriaging = false; return }

        let total = unread.count

        // Collect all AI results into a plain array off-main — zero @Published
        // mutations during the loop, so SwiftUI is never touched while triaging.
        let results: [TriageResult] = await Task.detached(priority: .utility) { [weak self] in
            var out: [TriageResult] = []
            for (index, email) in unread.enumerated() {
                // Only progress label needs a main-actor hop
                await MainActor.run { self?.triageProgress = "Triaging \(index + 1) of \(total)\u{2026}" }

                let body = email.fullBody.isEmpty ? email.bodyPreview : String(email.fullBody.prefix(1200))
                let prompt = """
                You are an email triage assistant. Decide if this email requires a direct response or action from the user.

                IGNORE: newsletters, marketing or promotional emails, automated alerts, social notifications, receipts, and ads.

                Distinguish between two types of actionable emails:
                - requiresReply true: the user must write a reply (e.g. someone asked a question, needs confirmation, sent a meeting invite requiring a response)
                - requiresReply false: user needs to take an action but does NOT need to reply (e.g. review a document, click a link, complete a task, attend an event)

                If requiresReply is true, also write a concise professional reply draft. Plain text body only \u{2014} no salutation, no signature.

                Also set "requiresMeeting" true if the email mentions a meeting, call, event, deadline, or any time-sensitive commitment that should be scheduled.

                Respond ONLY with valid JSON in one of these exact formats:
                {"actionable": true, "requiresReply": true, "requiresMeeting": true, "draftReply": "draft body here"}
                {"actionable": true, "requiresReply": true, "requiresMeeting": false, "draftReply": "draft body here"}
                {"actionable": true, "requiresReply": false, "requiresMeeting": false, "draftReply": ""}
                {"actionable": false, "requiresReply": false, "requiresMeeting": false, "draftReply": ""}

                Email:
                From: \(email.from)
                Subject: \(email.subject)
                Body: \(body)
                """

                do {
                    guard let raw = try await EmailStore.callAIBackground(
                        prompt: prompt, ep: ep, key: key, mdl: mdl, azure: azure, token: token
                    ) else {
                        out.append(TriageResult(id: email.id, actionable: false,
                                                requiresReply: false, requiresMeeting: false, draftBody: nil))
                        continue
                    }

                    var actionable      = false
                    var requiresReply   = false
                    var requiresMeeting = false
                    var draftBody:      String? = nil
                    if let jStart = raw.range(of: "{"),
                       let jEnd   = raw.range(of: "}", options: .backwards),
                       jStart.lowerBound <= jEnd.lowerBound,
                       let data = String(raw[jStart.lowerBound...jEnd.lowerBound]).data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        actionable      = (json["actionable"]      as? Bool) ?? false
                        requiresReply   = (json["requiresReply"]   as? Bool) ?? false
                        requiresMeeting = (json["requiresMeeting"] as? Bool) ?? false
                        let d = (json["draftReply"] as? String) ?? ""
                        if requiresReply && !d.isEmpty { draftBody = d }
                    }
                    out.append(TriageResult(id: email.id, actionable: actionable,
                                            requiresReply: requiresReply,
                                            requiresMeeting: requiresMeeting, draftBody: draftBody))
                } catch {
                    await MainActor.run { self?.triageError = "Triage stopped: \(error.localizedDescription)" }
                    return out
                }
            }
            return out
        }.value

        // ONE batch write to @Published emails → one SwiftUI diff, one save()
        for result in results {
            guard let idx = emails.firstIndex(where: { $0.id == result.id }) else { continue }
            emails[idx].isTriaged        = true
            emails[idx].isActionRequired = result.actionable
            emails[idx].requiresReply    = result.requiresReply
            emails[idx].requiresMeeting  = result.requiresMeeting
            if let d = result.draftBody  { emails[idx].aiDraftBody = d }
        }
        if !results.isEmpty { save() }
        lastTriageDate = Date()
        isTriaging = false
        triageProgress = nil
    }

    /// nonisolated static — explicitly off-main, safe to call from Task.detached
    nonisolated static func callAIBackground(
        prompt: String,
        ep: String, key: String, mdl: String, azure: Bool, token: String
    ) async throws -> String? {
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]

        if azure && !ep.isEmpty {
            guard let base = URL(string: ep), let host = base.host else {
                throw NSError(domain: "EmailTriage", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid Azure endpoint URL."])
            }
            let scheme = base.scheme ?? "https"
            guard let u = URL(string: "\(scheme)://\(host)/openai/models/chat/completions?api-version=2024-05-01-preview") else {
                throw NSError(domain: "EmailTriage", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid Azure endpoint URL."])
            }
            url = u
            if !key.isEmpty   { headers["api-key"]      = key }
            if !token.isEmpty { headers["X-User-Token"] = token }
        } else {
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            guard !key.isEmpty else {
                throw NSError(domain: "EmailTriage", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "No API key configured."])
            }
            headers["Authorization"] = "Bearer \(key)"
        }

        let body: [String: Any] = [
            "model":           mdl,
            "messages":        [["role": "user", "content": prompt]],
            "response_format": ["type": "json_object"],
            "temperature":     0
        ]

        var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.httpBody   = try JSONSerialization.data(withJSONObject: body)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? "(empty)"
            throw NSError(domain: "EmailTriage", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode): \(raw.prefix(200))"])
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            throw NSError(domain: "EmailTriage", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    // ── Persistence ────────────────────────────────────────────────────

    private func save() {
        // Encode off-main (can be slow for 500 emails), then write UserDefaults on main
        let snapshot = emails
        let key = udKey
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await MainActor.run {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([UnifiedEmail].self, from: data) else { return }
        emails = decoded
    }
}
