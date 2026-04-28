//
//  EmailAccountsManager.swift
//  pa-agent
//
//  Central store for all connected email accounts (multiple per provider supported).
//  Handles OAuth flows, per-account token management and exposes API helper methods
//  so EmailStore can fan out across every connected account.
//
//  Keychain layout per account:
//    service = "com.nexa.email.<accountId UUID string>"
//    keys    = "refreshToken", "accessToken"  (accessToken is optional cache)
//
//  Persistence:
//    accounts metadata (id, provider, email) → UserDefaults "nexaEmailAccounts" (JSON)
//    OAuth tokens → Keychain (see above)
//

import Foundation
import AuthenticationServices
import SwiftUI
import Combine

// ── Off-main token cache — its own actor executor, never needs the main actor ──
private actor TokenCache {
    private var entries: [UUID: (token: String, expiry: Date)] = [:]
    func get(_ id: UUID) -> (token: String, expiry: Date)? { entries[id] }
    func set(_ id: UUID, token: String, expiry: Date) { entries[id] = (token, expiry) }
    func remove(_ id: UUID) { entries.removeValue(forKey: id) }
}

@MainActor
final class EmailAccountsManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = EmailAccountsManager()

    private override init() {
        super.init()
        loadAccounts()
        migrateIfNeeded()
    }

    // ── Published state ────────────────────────────────────────────────
    @Published var accounts: [EmailAccount] = []
    @Published var isAddingAccount: Bool = false
    @Published var lastError: String?

    /// True if at least one account is connected.
    var hasAnyAccount: Bool { !accounts.isEmpty }

    private let udKey = "nexaEmailAccounts"

    // In-memory token cache lives in a dedicated actor — no main-actor hops needed
    private let tokenStore = TokenCache()

    // ── Persistence ────────────────────────────────────────────────────

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) else { return }
        accounts = decoded
    }

    // ── Migration from legacy single-account services ──────────────────

    /// If GmailService stored a refresh token under the old keychain key and we haven't
    /// yet imported it, create an EmailAccount and move the token.
    private func migrateIfNeeded() {
        // Gmail migration
        if let rt = legacyLoadFromKeychain(service: "com.nexa.gmail", key: "refreshToken"),
           let email = legacyLoadFromKeychain(service: "com.nexa.gmail", key: "email"),
           !accounts.contains(where: { $0.provider == .gmail && $0.email == email }) {
            let acct = EmailAccount(provider: .gmail, email: email)
            accounts.append(acct)
            saveToKeychain(accountId: acct.id, key: "refreshToken", value: rt)
            saveAccounts()
        }
        // Note: OutlookService intentionally clears its Keychain on init (disabled),
        // so no Outlook migration is needed.
    }

    // ── Add / Remove ───────────────────────────────────────────────────

    /// Launches the OAuth flow for the given provider and, on success, appends a new EmailAccount.
    func addAccount(provider: EmailProvider) async throws {
        isAddingAccount = true
        lastError = nil
        defer { isAddingAccount = false }

        switch provider {
        case .gmail:
            try await addGmailAccount()
        case .outlook:
            try await addOutlookAccount()
        }
    }

    func removeAccount(_ account: EmailAccount) {
        accounts.removeAll { $0.id == account.id }
        Task { await self.tokenStore.remove(account.id) }
        deleteKeychain(accountId: account.id)
        saveAccounts()
    }

    func accounts(for provider: EmailProvider) -> [EmailAccount] {
        accounts.filter { $0.provider == provider }
    }

    // ── Access token ───────────────────────────────────────────────────

    nonisolated func accessToken(for account: EmailAccount) async throws -> String {
        // Use cache if still valid (60-second buffer)
        if let cached = await tokenStore.get(account.id), Date() < cached.expiry.addingTimeInterval(-60) {
            return cached.token
        }
        // Refresh
        guard let rt = loadFromKeychain(accountId: account.id, key: "refreshToken") else {
            throw AccountError.noRefreshToken
        }
        switch account.provider {
        case .gmail:
            return try await refreshGmailToken(account: account, refreshToken: rt)
        case .outlook:
            return try await refreshOutlookToken(account: account, refreshToken: rt)
        }
    }

    // ── Gmail OAuth ────────────────────────────────────────────────────

    private func addGmailAccount() async throws {
        let state = UUID().uuidString
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id",     value: GmailService.clientID),
            .init(name: "redirect_uri",  value: GmailService.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope",         value: gmailScopes),
            .init(name: "state",         value: state),
            .init(name: "access_type",   value: "offline"),
            .init(name: "prompt",        value: "consent")
        ]

        let callbackURL = try await runASWebAuth(url: comps.url!, callbackScheme: GmailService.redirectURIScheme)

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AccountError.missingAuthCode }

        // Exchange code
        let (accessToken, refreshToken, expiry) = try await exchangeGmailCode(code)

        // Fetch profile email
        let email = try await fetchGmailEmail(token: accessToken)

        // Avoid duplicates — update existing if same email
        if let idx = accounts.firstIndex(where: { $0.provider == .gmail && $0.email == email }) {
            let acct = accounts[idx]
            await tokenStore.set(acct.id, token: accessToken, expiry: expiry)
            if let rt = refreshToken { saveToKeychain(accountId: acct.id, key: "refreshToken", value: rt) }
            return
        }

        let acct = EmailAccount(provider: .gmail, email: email)
        await tokenStore.set(acct.id, token: accessToken, expiry: expiry)
        if let rt = refreshToken { saveToKeychain(accountId: acct.id, key: "refreshToken", value: rt) }
        accounts.append(acct)
        saveAccounts()
    }

    private func exchangeGmailCode(_ code: String) async throws -> (String, String?, Date) {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = [
            "code":         code,
            "client_id":    GmailService.clientID,
            "redirect_uri": GmailService.redirectURI,
            "grant_type":   "authorization_code"
        ]
        req.httpBody = encodeForm(body)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
        return (json.access_token, json.refresh_token, expiry)
    }

    nonisolated private func refreshGmailToken(account: EmailAccount, refreshToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = [
            "refresh_token": refreshToken,
            "client_id":     GmailService.clientID,
            "grant_type":    "refresh_token"
        ]
        req.httpBody = encodeForm(body)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
        await tokenStore.set(account.id, token: json.access_token, expiry: expiry)
        return json.access_token
    }

    private func fetchGmailEmail(token: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = obj["email"] as? String else {
            throw AccountError.profileFetchFailed
        }
        return email
    }

    private let gmailScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify"
    ].joined(separator: " ")

    // ── Outlook OAuth ──────────────────────────────────────────────────

    private func addOutlookAccount() async throws {
        let state = UUID().uuidString
        var comps = URLComponents(string: "\(OutlookService.authority)/oauth2/v2.0/authorize")!
        comps.queryItems = [
            .init(name: "client_id",     value: OutlookService.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri",  value: OutlookService.redirectURI),
            .init(name: "scope",         value: outlookScopes),
            .init(name: "state",         value: state),
            .init(name: "prompt",        value: "select_account"),
            .init(name: "response_mode", value: "query")
        ]

        let callbackScheme = "msauth.z.Nexa.outlook"
        let callbackURL = try await runASWebAuth(url: comps.url!, callbackScheme: callbackScheme)

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AccountError.missingAuthCode }

        let (accessToken, refreshToken, expiry) = try await exchangeOutlookCode(code)
        let email = try await fetchOutlookEmail(token: accessToken)

        // Avoid duplicates
        if let idx = accounts.firstIndex(where: { $0.provider == .outlook && $0.email == email }) {
            let acct = accounts[idx]
            await tokenStore.set(acct.id, token: accessToken, expiry: expiry)
            if let rt = refreshToken { saveToKeychain(accountId: acct.id, key: "refreshToken", value: rt) }
            return
        }

        let acct = EmailAccount(provider: .outlook, email: email)
        await tokenStore.set(acct.id, token: accessToken, expiry: expiry)
        if let rt = refreshToken { saveToKeychain(accountId: acct.id, key: "refreshToken", value: rt) }
        accounts.append(acct)
        saveAccounts()
    }

    private func exchangeOutlookCode(_ code: String) async throws -> (String, String?, Date) {
        var req = URLRequest(url: URL(string: "\(OutlookService.authority)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = [
            "client_id":    OutlookService.clientID,
            "code":         code,
            "redirect_uri": OutlookService.redirectURI,
            "grant_type":   "authorization_code",
            "scope":        outlookScopes
        ]
        req.httpBody = encodeForm(body)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
        return (json.access_token, json.refresh_token, expiry)
    }

    nonisolated private func refreshOutlookToken(account: EmailAccount, refreshToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(OutlookService.authority)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = [
            "client_id":     OutlookService.clientID,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token",
            "scope":         outlookScopes
        ]
        req.httpBody = encodeForm(body)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
        await tokenStore.set(account.id, token: json.access_token, expiry: expiry)
        return json.access_token
    }

    private func fetchOutlookEmail(token: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Prefer mail (set for M365), fall back to userPrincipalName (always present)
            if let mail = (obj["mail"] ?? obj["userPrincipalName"]) as? String {
                return mail
            }
            // Surface the Graph error message if present
            if let errObj = obj["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw NSError(domain: "OutlookProfile", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Microsoft Graph: \(msg)"])
            }
        }
        throw AccountError.profileFetchFailed
    }

    private let outlookScopes = "offline_access User.Read Mail.Read Mail.Send Mail.ReadWrite"

    // ── Gmail API helpers (token-based, account-scoped) ────────────────

    nonisolated func gmailFetchThreadList(account: EmailAccount, maxResults: Int = 20) async throws -> [String] {
        let token = try await accessToken(for: account)
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
        comps.queryItems = [
            .init(name: "labelIds",   value: "INBOX"),
            .init(name: "maxResults", value: "\(maxResults)")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    nonisolated func gmailFetchThread(account: EmailAccount, threadId: String) async throws -> [UnifiedEmail] {
        let token = try await accessToken(for: account)
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)?format=full")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.compactMap { parseGmailMessage($0, threadId: threadId, accountId: account.id, accountEmail: account.email) }
    }

    func gmailModifyLabels(account: EmailAccount, messageId: String, add: [String] = [], remove: [String] = []) async throws {
        let token = try await accessToken(for: account)
        let body: [String: Any] = ["addLabelIds": add, "removeLabelIds": remove]
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/modify")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    func gmailSend(account: EmailAccount, draft: EmailDraft) async throws {
        let token = try await accessToken(for: account)
        let raw = buildGmailRFC2822(from: account.email, draft: draft)
        let encoded = raw.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var body: [String: Any] = ["raw": encoded]
        if let tid = draft.inReplyToThreadId { body["threadId"] = tid }
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw AccountError.httpError(http.statusCode)
        }
    }

    // ── Outlook API helpers ────────────────────────────────────────────

    nonisolated func outlookFetchInbox(account: EmailAccount, maxResults: Int = 20) async throws -> [UnifiedEmail] {
        let token = try await accessToken(for: account)
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages")!
        comps.queryItems = [
            .init(name: "$top",     value: "\(maxResults)"),
            .init(name: "$select",  value: "id,conversationId,subject,from,toRecipients,bodyPreview,body,receivedDateTime,isRead,flag"),
            .init(name: "$orderby", value: "receivedDateTime desc")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json["value"] as? [[String: Any]] ?? []).compactMap { parseOutlookMessage($0, accountId: account.id) }
    }

    func outlookMarkRead(account: EmailAccount, messageId: String) async throws {
        let token = try await accessToken(for: account)
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(messageId)")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["isRead": true])
        _ = try await URLSession.shared.data(for: req)
    }

    func outlookSend(account: EmailAccount, draft: EmailDraft) async throws {
        let token = try await accessToken(for: account)
        // /reply requires the individual message ID — NOT the conversationId stored in threadId
        if let msgId = draft.replyToMessageId ?? draft.inReplyToThreadId {
            var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(msgId)/reply")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["comment": draft.body])
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                throw AccountError.httpError(http.statusCode)
            }
            return
        }
        let body: [String: Any] = [
            "message": [
                "subject": draft.subject,
                "body": ["contentType": "Text", "content": draft.body],
                "toRecipients": [["emailAddress": ["address": draft.to]]]
            ] as [String: Any],
            "saveToSentItems": true
        ]
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw AccountError.httpError(http.statusCode)
        }
    }

    // ── ASWebAuthenticationSession ─────────────────────────────────────

    private func runASWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { cbURL, err in
                if let err { cont.resume(throwing: err) }
                else if let cbURL { cont.resume(returning: cbURL) }
                else { cont.resume(throwing: AccountError.noCallbackURL) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // ── Parsing helpers ────────────────────────────────────────────────

    nonisolated private func parseGmailMessage(_ msg: [String: Any], threadId: String, accountId: UUID, accountEmail: String) -> UnifiedEmail? {
        guard let msgId = msg["id"] as? String else { return nil }
        let payload = msg["payload"] as? [String: Any] ?? [:]
        let headers = (payload["headers"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            if let n = $1["name"] as? String, let v = $1["value"] as? String { $0[n.lowercased()] = v }
        }
        let from    = headers["from"] ?? ""
        let subject = headers["subject"] ?? "(no subject)"
        let date    = parseRFC2822Date(headers["date"] ?? "") ?? Date()
        let body    = extractGmailBody(payload: payload)
        let labelIds = msg["labelIds"] as? [String] ?? []
        return UnifiedEmail(
            id: msgId, provider: .gmail, accountId: accountId, threadId: threadId,
            from: from, fromName: extractDisplayName(from: from),
            toRecipients: [headers["to"] ?? ""],
            subject: subject, bodyPreview: String(body.prefix(200)), fullBody: body,
            date: date, isRead: !labelIds.contains("UNREAD"), isFlagged: labelIds.contains("STARRED"),
            priority: .normal, aiSummary: nil, aiPriorityReason: nil, labels: labelIds
        )
    }

    nonisolated private func parseOutlookMessage(_ msg: [String: Any], accountId: UUID) -> UnifiedEmail? {
        guard let msgId = msg["id"] as? String else { return nil }
        let threadId = msg["conversationId"] as? String ?? msgId
        let subject  = msg["subject"] as? String ?? "(no subject)"
        let preview  = msg["bodyPreview"] as? String ?? ""
        let fromObj  = (msg["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
        let fromAddr = fromObj?["address"] as? String ?? ""
        let fromName = fromObj?["name"] as? String ?? fromAddr
        let isRead   = msg["isRead"] as? Bool ?? true
        let flagged  = ((msg["flag"] as? [String: Any])?["flagStatus"] as? String ?? "") == "flagged"
        let body     = (msg["body"] as? [String: Any])?["content"] as? String ?? preview
        let date     = ISO8601DateFormatter().date(from: msg["receivedDateTime"] as? String ?? "") ?? Date()
        let to       = (msg["toRecipients"] as? [[String: Any]] ?? []).compactMap {
            ($0["emailAddress"] as? [String: Any])?["address"] as? String
        }
        return UnifiedEmail(
            id: msgId, provider: .outlook, accountId: accountId, threadId: threadId,
            from: "\(fromName) <\(fromAddr)>", fromName: fromName,
            toRecipients: to,
            subject: subject, bodyPreview: preview, fullBody: stripHTML(body),
            date: date, isRead: isRead, isFlagged: flagged,
            priority: .normal, aiSummary: nil, aiPriorityReason: nil, labels: []
        )
    }

    nonisolated private func extractGmailBody(payload: [String: Any]) -> String {
        if let bd = (payload["body"] as? [String: Any])?["data"] as? String { return decodeBase64URL(bd) }
        let parts = payload["parts"] as? [[String: Any]] ?? []
        for part in parts {
            if (part["mimeType"] as? String) == "text/plain",
               let bd = (part["body"] as? [String: Any])?["data"] as? String { return decodeBase64URL(bd) }
        }
        for part in parts {
            if (part["mimeType"] as? String) == "text/html",
               let bd = (part["body"] as? [String: Any])?["data"] as? String { return stripHTML(decodeBase64URL(bd)) }
        }
        return ""
    }

    nonisolated private func decodeBase64URL(_ s: String) -> String {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return String(data: Data(base64Encoded: b64) ?? Data(), encoding: .utf8) ?? ""
    }

    nonisolated private func stripHTML(_ html: String) -> String {
        guard let d = html.data(using: .utf8),
              let attr = try? NSAttributedString(data: d,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil) else {
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return attr.string
    }

    nonisolated private func extractDisplayName(from: String) -> String {
        if let range = from.range(of: "<") {
            return String(from[from.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return from
    }

    nonisolated private func parseRFC2822Date(_ s: String) -> Date? {
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z"]
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts { df.dateFormat = fmt; if let d = df.date(from: s) { return d } }
        return nil
    }

    private func buildGmailRFC2822(from: String, draft: EmailDraft) -> String {
        let cc = draft.cc.isEmpty ? "" : "Cc: \(draft.cc)\r\n"
        var replyHeaders = ""
        if let msgId = draft.replyToMessageId {
            let bracketed = msgId.hasPrefix("<") ? msgId : "<\(msgId)>"
            replyHeaders = "In-Reply-To: \(bracketed)\r\nReferences: \(bracketed)\r\n"
        }
        return "From: \(from)\r\nTo: \(draft.to)\r\n\(cc)Subject: \(draft.subject)\r\n\(replyHeaders)Content-Type: text/plain; charset=utf-8\r\nMIME-Version: 1.0\r\n\r\n\(draft.body)"
    }

    // ── Keychain helpers ───────────────────────────────────────────────

    nonisolated private func keychainService(for accountId: UUID) -> String {
        "com.nexa.email.\(accountId.uuidString)"
    }

    nonisolated func saveToKeychain(accountId: UUID, key: String, value: String) {
        let service = keychainService(for: accountId)
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attrs = query; attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    nonisolated func loadFromKeychain(accountId: UUID, key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService(for: accountId),
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain(accountId: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService(for: accountId)]
        SecItemDelete(query as CFDictionary)
    }

    private func legacyLoadFromKeychain(service: String, key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // ── Misc helpers ───────────────────────────────────────────────────

    nonisolated private func encodeForm(_ params: [String: String]) -> Data? {
        params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
              .joined(separator: "&")
              .data(using: .utf8)
    }
}

// MARK: - Errors

enum AccountError: LocalizedError {
    case missingAuthCode
    case noCallbackURL
    case noRefreshToken
    case profileFetchFailed
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingAuthCode:    return "Authorization code was not returned."
        case .noCallbackURL:      return "No callback URL received from browser."
        case .noRefreshToken:     return "No refresh token stored. Please sign in again."
        case .profileFetchFailed: return "Could not fetch account profile."
        case .httpError(let c):   return "HTTP error \(c)."
        }
    }
}

// MARK: - Private Codable

private struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}
