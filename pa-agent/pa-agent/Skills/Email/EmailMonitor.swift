//
//  EmailMonitor.swift
//  pa-agent
//
//  Background email monitor — runs every hour (silent, no UI state changes).
//  On each tick it:
//    1. Refreshes the inbox.
//    2. Diffs current unread IDs against the IDs seen on the previous run.
//    3. Triages only the NEW unread emails via AI (Task.detached — off-main).
//    4. Writes results back with EmailStore.applyTriageResults (one batch write).
//    5. Posts nexaEmailActionReady if any new emails are actionable.
//

import Foundation
import Combine

@MainActor
final class EmailMonitor: ObservableObject {

    static let shared = EmailMonitor()
    private init() {}

    // ── State ──────────────────────────────────────────────────────────
    @Published var isRunning: Bool = false

    private var cancellable: AnyCancellable?

    // IDs seen on the previous monitor run — diff source for "new unread" detection
    // nonisolated: wraps UserDefaults which is thread-safe
    nonisolated var seenUnreadIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: udSeenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: udSeenKey) }
    }
    private let udSeenKey = "nexaEmailMonitorSeenIds"

    // IDs already notified — prevents re-posting the same chat card
    nonisolated var notifiedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: udNotifiedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: udNotifiedKey) }
    }
    private let udNotifiedKey = "nexaEmailMonitorNotifiedIds"

    // ── Lifecycle ──────────────────────────────────────────────────────

    func startMonitoring() {
        guard cancellable == nil else { return }
        isRunning = true
        cancellable = Timer.publish(every: 60 * 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Task.detached: checkNow is nonisolated — runs entirely off the main actor
                Task.detached(priority: .background) { [weak self] in
                    await self?.checkNow()
                }
            }
    }

    func stopMonitoring() {
        cancellable?.cancel()
        cancellable = nil
        isRunning = false
    }

    // ── Main check — nonisolated: never touches the main actor directly ───

    /// Entry point for both the hourly timer and manual checkNow() calls.
    /// Runs entirely off the main actor; only tiny MainActor.run hops for state.
    nonisolated func checkNow() async {
        // Precondition: need at least one linked account
        let hasAccount = await MainActor.run { EmailAccountsManager.shared.hasAnyAccount }
        guard hasAccount else { return }

        // 1. Refresh inbox — @MainActor func, but it immediately launches
        //    Task.detached for all network work and only writes @Published on completion.
        //    The main actor is free during all I/O.
        await EmailStore.shared.refresh()

        // 2. Single main-actor hop: snapshot emails + compute diff + update seenIds
        let (newIds, candidates): (Set<String>, [UnifiedEmail]) = await MainActor.run { [self] in
            let currentIds = Set(EmailStore.shared.emails.filter { !$0.isRead }.map { $0.id })
            let prev       = self.seenUnreadIds
            let diff       = currentIds.subtracting(prev)
            self.seenUnreadIds = currentIds
            let cands = EmailStore.shared.emails.filter { diff.contains($0.id) }
            return (diff, cands)
        }
        guard !newIds.isEmpty else { return }

        // 3. Triage only the new emails — fully off-main
        let actionableIds = await triageNewEmails(candidates)

        // 4. Notify chat — another tiny main-actor hop for notifiedIds state
        await MainActor.run { [self] in
            let fresh = actionableIds.subtracting(self.notifiedIds)
            guard !fresh.isEmpty else { return }
            NotificationCenter.default.post(
                name: .nexaEmailActionReady,
                object: nil,
                userInfo: ["count": fresh.count, "ids": Array(fresh)]
            )
            var known = self.notifiedIds
            known.formUnion(fresh)
            if known.count > 500 { known = Set(known.sorted().suffix(300)) }
            self.notifiedIds = known
        }
    }

    // ── Background triage — nonisolated, zero main-actor involvement ──────────

    /// Triages `candidates` entirely off-main. Writes results via applyTriageResults.
    /// Returns IDs the AI flagged as actionable.
    nonisolated private func triageNewEmails(_ candidates: [UnifiedEmail]) async -> Set<String> {
        let ud       = UserDefaults.standard
        let apiKey   = ud.string(forKey: AppConfig.Keys.apiKey)        ?? ""
        let model    = ud.string(forKey: AppConfig.Keys.model)         ?? AppConfig.Defaults.model
        let useAzure = ud.bool(forKey: AppConfig.Keys.useAzure)
        let azureEp  = ud.string(forKey: AppConfig.Keys.azureEndpoint) ?? ""
        guard !apiKey.isEmpty else { return [] }

        // Value-type snapshot — safe to cross actor boundary
        let emails = candidates

        typealias TResult = (id: String, actionable: Bool, requiresReply: Bool, draftBody: String?)

        let results: [TResult] = await Task.detached(priority: .utility) {
            var out: [TResult] = []
            for email in emails {
                let body = email.fullBody.isEmpty ? email.bodyPreview : String(email.fullBody.prefix(1200))
                let prompt = """
                You are an email triage assistant. Decide if this email requires a direct response or action from the user.

                IGNORE: newsletters, marketing or promotional emails, automated alerts, social notifications, receipts, and ads.

                Distinguish between two types of actionable emails:
                - requiresReply true: the user must write a reply (e.g. someone asked a question, needs confirmation, sent a meeting invite requiring a response)
                - requiresReply false: user needs to take an action but does NOT need to reply (e.g. review a document, click a link, complete a task, attend an event)

                If requiresReply is true, also write a concise professional reply draft. Plain text body only \u{2014} no salutation, no signature.

                Respond ONLY with valid JSON in one of these exact formats:
                {"actionable": true, "requiresReply": true, "draftReply": "draft body here"}
                {"actionable": true, "requiresReply": false, "draftReply": ""}
                {"actionable": false, "requiresReply": false, "draftReply": ""}

                Email:
                From: \(email.from)
                Subject: \(email.subject)
                Body: \(body)
                """
                do {
                    guard let raw = try await EmailMonitor.callAIStatic(
                        prompt: prompt, apiKey: apiKey, model: model,
                        useAzure: useAzure, azureEndpoint: azureEp
                    ) else {
                        out.append((email.id, false, false, nil))
                        continue
                    }
                    var actionable    = false
                    var requiresReply = false
                    var draftBody:    String? = nil
                    if let jStart = raw.range(of: "{"),
                       let jEnd   = raw.range(of: "}", options: .backwards),
                       jStart.lowerBound <= jEnd.lowerBound,
                       let data = String(raw[jStart.lowerBound...jEnd.lowerBound]).data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        actionable    = (json["actionable"]    as? Bool) ?? false
                        requiresReply = (json["requiresReply"] as? Bool) ?? false
                        let d = (json["draftReply"] as? String) ?? ""
                        if requiresReply && !d.isEmpty { draftBody = d }
                    }
                    out.append((email.id, actionable, requiresReply, draftBody))
                } catch {
                    print("[EmailMonitor] triage error for \(email.id): \(error)")
                    out.append((email.id, false, false, nil))
                }
            }
            return out
        }.value

        // Batch-write to store on main actor — one @Published mutation, one save()
        await MainActor.run {
            EmailStore.shared.applyTriageResults(results)
        }

        return Set(results.filter { $0.actionable }.map { $0.id })
    }

    // ── AI helper (nonisolated — no actor, safe from Task.detached) ──────

    nonisolated static func callAIStatic(
        prompt: String,
        apiKey: String,
        model: String,
        useAzure: Bool,
        azureEndpoint: String
    ) async throws -> String? {
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]

        if useAzure && !azureEndpoint.isEmpty {
            guard let base = URL(string: azureEndpoint), let host = base.host else { return nil }
            let scheme = base.scheme ?? "https"
            guard let u = URL(string: "\(scheme)://\(host)/openai/models/chat/completions?api-version=2024-05-01-preview")
            else { return nil }
            url = u
            if !apiKey.isEmpty { headers["api-key"] = apiKey }
        } else {
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            guard !apiKey.isEmpty else { return nil }
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        let body: [String: Any] = [
            "model":           model.isEmpty ? AppConfig.Defaults.model : model,
            "messages":        [["role": "user", "content": prompt]],
            "response_format": ["type": "json_object"],
            "temperature":     0
        ]

        var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.httpBody   = try JSONSerialization.data(withJSONObject: body)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }
}

// MARK: - Notification names
extension Notification.Name {
    static let nexaEmailActionReady = Notification.Name("nexaEmailActionReady")
    static let nexaOpenEmailDraft   = Notification.Name("nexaOpenEmailDraft")
    static let nexaAddTaskFromEmail = Notification.Name("nexaAddTaskFromEmail")
}
