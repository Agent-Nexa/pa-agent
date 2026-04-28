//
//  GmailService.swift
//  pa-agent
//
//  Gmail integration using OAuth 2.0 via ASWebAuthenticationSession (no extra SDK).
//  Tokens are stored in the device Keychain.
//
//  Setup required:
//  1. Create an iOS OAuth 2.0 client in Google Cloud Console for bundle ID "z.Nexa".
//  2. Set GmailService.clientID and GmailService.redirectURIScheme to match.
//  3. Add the redirectURIScheme as a URL scheme in nexa-Info.plist.
//

import Foundation
import AuthenticationServices
import Combine
import SwiftUI

@MainActor
final class GmailService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = GmailService()
    private override init() { super.init() }

    // ── Configuration ──────────────────────────────────────────────────
    // Fill in after registering an iOS OAuth client in Google Cloud Console.
    static let clientID          = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
    static let redirectURIScheme = "com.googleusercontent.apps.YOUR_GOOGLE_CLIENT_ID"
    static let redirectURI       = "\(redirectURIScheme):/oauth2redirect"

    private let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify"
    ].joined(separator: " ")

    private let keychainService = "com.nexa.gmail"

    // ── Published state ────────────────────────────────────────────────
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var connectedEmail: String = ""
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var lastError: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    // ── Lifecycle ──────────────────────────────────────────────────────

    func restoreSession() async {
        guard let rt = loadFromKeychain(key: "refreshToken"),
              let email = loadFromKeychain(key: "email") else { return }
        refreshToken = rt
        connectedEmail = email
        do {
            try await refreshAccessToken()
            isSignedIn = true
        } catch {
            isSignedIn = false
        }
    }

    // ── Sign In ────────────────────────────────────────────────────────

    func signIn() async throws {
        isBusy = true; defer { isBusy = false }

        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id",       value: Self.clientID),
            .init(name: "redirect_uri",    value: Self.redirectURI),
            .init(name: "response_type",   value: "code"),
            .init(name: "scope",           value: scopes),
            .init(name: "state",           value: state),
            .init(name: "access_type",     value: "offline"),
            .init(name: "prompt",          value: "consent")
        ]
        let authURL = components.url!
        let callbackScheme = Self.redirectURIScheme

        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, err in
                if let err { cont.resume(throwing: err) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: NSError(domain: "GmailService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No callback URL"])) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw NSError(domain: "GmailService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing auth code"]) }

        try await exchangeCode(code)
        try await fetchProfile()
        isSignedIn = true
    }

    func signOut() {
        accessToken  = nil
        refreshToken = nil
        tokenExpiry  = nil
        connectedEmail = ""
        isSignedIn   = false
        deleteFromKeychain(key: "refreshToken")
        deleteFromKeychain(key: "email")
    }

    // ── Token exchange / refresh ───────────────────────────────────────

    private func exchangeCode(_ code: String) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = [
            "code":          code,
            "client_id":     Self.clientID,
            "redirect_uri":  Self.redirectURI,
            "grant_type":    "authorization_code"
        ]
        req.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken   = json.access_token
        refreshToken  = json.refresh_token ?? refreshToken
        tokenExpiry   = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
        if let rt = refreshToken { saveToKeychain(key: "refreshToken", value: rt) }
    }

    func refreshAccessToken() async throws {
        guard let rt = refreshToken else { throw NSError(domain: "GmailService", code: -3, userInfo: [NSLocalizedDescriptionKey: "No refresh token"]) }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = ["refresh_token": rt, "client_id": Self.clientID, "grant_type": "refresh_token"]
        req.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken  = json.access_token
        tokenExpiry  = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
    }

    private func validToken() async throws -> String {
        if let exp = tokenExpiry, Date() >= exp.addingTimeInterval(-60) {
            try await refreshAccessToken()
        }
        guard let t = accessToken else { throw NSError(domain: "GmailService", code: -4, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]) }
        return t
    }

    // ── Profile ────────────────────────────────────────────────────────

    private func fetchProfile() async throws {
        let token = try await validToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = obj["email"] as? String {
            connectedEmail = email
            saveToKeychain(key: "email", value: email)
        }
    }

    // ── Inbox ──────────────────────────────────────────────────────────

    /// Fetches a page of thread IDs from the inbox.
    func fetchThreadList(maxResults: Int = 20, pageToken: String? = nil) async throws -> (threads: [String], nextPageToken: String?) {
        let token = try await validToken()
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
        var items: [URLQueryItem] = [
            .init(name: "labelIds",   value: "INBOX"),
            .init(name: "maxResults", value: "\(maxResults)")
        ]
        if let pt = pageToken { items.append(.init(name: "pageToken", value: pt)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let ids = (json["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let next = json["nextPageToken"] as? String
        return (ids, next)
    }

    /// Fetches a full thread and normalises every message into UnifiedEmail.
    func fetchThread(id: String) async throws -> [UnifiedEmail] {
        let token = try await validToken()
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?format=full")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.compactMap { parseMessage($0, threadId: id) }
    }

    // ── Send ───────────────────────────────────────────────────────────

    func sendEmail(draft: EmailDraft) async throws {
        let token = try await validToken()
        let raw = buildRFC2822(draft: draft)
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
            throw NSError(domain: "GmailService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Send failed HTTP \(http.statusCode)"])
        }
    }

    /// Mark a message read/unread or add/remove labels.
    func modifyLabels(messageId: String, add: [String] = [], remove: [String] = []) async throws {
        let token = try await validToken()
        let body: [String: Any] = ["addLabelIds": add, "removeLabelIds": remove]
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/modify")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    // ── Helpers ────────────────────────────────────────────────────────

    private func parseMessage(_ msg: [String: Any], threadId: String) -> UnifiedEmail? {
        guard let msgId = msg["id"] as? String else { return nil }
        let payload   = msg["payload"] as? [String: Any] ?? [:]
        let headers   = (payload["headers"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            if let n = $1["name"] as? String, let v = $1["value"] as? String { $0[n.lowercased()] = v }
        }
        let from    = headers["from"] ?? ""
        let subject = headers["subject"] ?? "(no subject)"
        let dateStr = headers["date"] ?? ""
        let date    = parseRFC2822Date(dateStr) ?? Date()

        let body    = extractBody(payload: payload)
        let preview = String(body.prefix(200))

        let labelIds = msg["labelIds"] as? [String] ?? []
        let isRead   = !labelIds.contains("UNREAD")
        let flagged  = labelIds.contains("STARRED")

        return UnifiedEmail(
            id: msgId, provider: .gmail, threadId: threadId,
            from: from, fromName: extractName(from: from),
            toRecipients: [headers["to"] ?? ""],
            subject: subject, bodyPreview: preview, fullBody: body,
            date: date, isRead: isRead, isFlagged: flagged,
            priority: .normal, aiSummary: nil, aiPriorityReason: nil,
            labels: labelIds
        )
    }

    private func extractBody(payload: [String: Any]) -> String {
        // Try body.data first
        if let bd = (payload["body"] as? [String: Any])?["data"] as? String {
            return decodeBase64URL(bd)
        }
        // Then recurse into parts
        let parts = payload["parts"] as? [[String: Any]] ?? []
        for part in parts {
            let mime = part["mimeType"] as? String ?? ""
            if mime == "text/plain", let bd = (part["body"] as? [String: Any])?["data"] as? String {
                return decodeBase64URL(bd)
            }
        }
        // Fallback to HTML part
        for part in parts {
            let mime = part["mimeType"] as? String ?? ""
            if mime == "text/html", let bd = (part["body"] as? [String: Any])?["data"] as? String {
                return stripHTML(decodeBase64URL(bd))
            }
        }
        return ""
    }

    private func decodeBase64URL(_ s: String) -> String {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let data = Data(base64Encoded: b64) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func stripHTML(_ html: String) -> String {
        guard let d = html.data(using: .utf8),
              let attr = try? NSAttributedString(data: d,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil) else {
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return attr.string
    }

    private func extractName(from: String) -> String {
        // "John Doe <john@example.com>" → "John Doe"
        if let range = from.range(of: "<") {
            return String(from[from.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return from
    }

    private func parseRFC2822Date(_ s: String) -> Date? {
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z"]
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    private func buildRFC2822(draft: EmailDraft) -> String {
        let cc = draft.cc.isEmpty ? "" : "Cc: \(draft.cc)\r\n"
        let inReplyTo = draft.replyToMessageId.map { "In-Reply-To: <\($0)>\r\nReferences: <\($0)>\r\n" } ?? ""
        return "From: \(connectedEmail)\r\nTo: \(draft.to)\r\n\(cc)Subject: \(draft.subject)\r\n\(inReplyTo)Content-Type: text/plain; charset=utf-8\r\nMIME-Version: 1.0\r\n\r\n\(draft.body)"
    }

    // ── ASWebAuthenticationPresentationContextProviding ────────────────
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // ── Keychain helpers ───────────────────────────────────────────────
    private func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: keychainService,
                                     kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attrs = query; attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }
    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: keychainService,
                                     kSecAttrAccount as String: key,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: keychainService,
                                     kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Codable helpers

private struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}
