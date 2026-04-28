//
//  OutlookService.swift
//  pa-agent
//
//  Microsoft Graph / Outlook integration using OAuth 2.0 via ASWebAuthenticationSession.
//
//  Azure app registration (one-time setup — you do this, not the user):
//  1. portal.azure.com → Azure Active Directory → App registrations → New registration.
//  2. Supported account types: choose the THIRD option:
//     "Accounts in any organizational directory (Multitenant) AND personal Microsoft accounts"
//     This lets ANY user sign in (Outlook.com, Hotmail, Live, M365) with no per-customer setup.
//  3. Redirect URI platform: "Mobile and desktop applications"
//     URI value: msauth.z.Nexa.outlook://auth
//  4. After creation, copy the Application (client) ID and paste it as clientID below.
//  5. API Permissions → Add → Microsoft Graph → Delegated:
//     Mail.Read, Mail.Send, Mail.ReadWrite, offline_access, User.Read
//     Then click "Grant admin consent".
//

import Foundation
import AuthenticationServices
import Combine
import SwiftUI

@MainActor
final class OutlookService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = OutlookService()
    private override init() { super.init() }

    // ── Configuration ──────────────────────────────────────────────────
    // Paste your Azure Application (client) ID here after completing the registration above.
    static let clientID      = "ed4f25c3-a864-4d4b-ad7b-c2910225532d"
    static let redirectURI   = "msauth.z.Nexa.outlook://auth"
    static let authority     = "https://login.microsoftonline.com/common"

    private let scopes = "offline_access User.Read Mail.Read Mail.Send Mail.ReadWrite"
    private let keychainService = "com.nexa.outlook"

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
        var comps = URLComponents(string: "\(Self.authority)/oauth2/v2.0/authorize")!
        comps.queryItems = [
            .init(name: "client_id",      value: Self.clientID),
            .init(name: "response_type",  value: "code"),
            .init(name: "redirect_uri",   value: Self.redirectURI),
            .init(name: "scope",          value: scopes),
            .init(name: "state",          value: state),
            .init(name: "prompt",         value: "select_account"),
            .init(name: "response_mode",  value: "query")
        ]
        let authURL = comps.url!
        let callbackScheme = "msauth.z.Nexa.outlook"

        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, err in
                if let err { cont.resume(throwing: err) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: NSError(domain: "OutlookService", code: -1)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw NSError(domain: "OutlookService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing auth code"]) }

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
        var req = URLRequest(url: URL(string: "\(Self.authority)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = [
            "client_id":    Self.clientID,
            "code":         code,
            "redirect_uri": Self.redirectURI,
            "grant_type":   "authorization_code",
            "scope":        scopes
        ]
        req.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken  = json.access_token
        refreshToken = json.refresh_token ?? refreshToken
        tokenExpiry  = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
        if let rt = refreshToken { saveToKeychain(key: "refreshToken", value: rt) }
    }

    func refreshAccessToken() async throws {
        guard let rt = refreshToken else { throw NSError(domain: "OutlookService", code: -3) }
        var req = URLRequest(url: URL(string: "\(Self.authority)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        let body: [String: String] = ["client_id": Self.clientID, "refresh_token": rt, "grant_type": "refresh_token", "scope": scopes]
        req.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = json.access_token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(json.expires_in ?? 3600))
    }

    private func validToken() async throws -> String {
        if let exp = tokenExpiry, Date() >= exp.addingTimeInterval(-60) {
            try await refreshAccessToken()
        }
        guard let t = accessToken else { throw NSError(domain: "OutlookService", code: -4) }
        return t
    }

    // ── Profile ────────────────────────────────────────────────────────

    private func fetchProfile() async throws {
        let token = try await validToken()
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mail = (obj["mail"] ?? obj["userPrincipalName"]) as? String {
            connectedEmail = mail
            saveToKeychain(key: "email", value: mail)
        }
    }

    // ── Inbox ──────────────────────────────────────────────────────────

    func fetchInbox(maxResults: Int = 20, skipToken: String? = nil) async throws -> (emails: [UnifiedEmail], nextSkipToken: String?) {
        let token = try await validToken()
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages")!
        var items: [URLQueryItem] = [
            .init(name: "$top",     value: "\(maxResults)"),
            .init(name: "$select",  value: "id,conversationId,subject,from,toRecipients,bodyPreview,body,receivedDateTime,isRead,flag"),
            .init(name: "$orderby", value: "receivedDateTime desc")
        ]
        if let skip = skipToken { items.append(.init(name: "$skiptoken", value: skip)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let messages = json["value"] as? [[String: Any]] ?? []
        let emails = messages.compactMap { parseMessage($0) }
        let next: String? = {
            guard let link = json["@odata.nextLink"] as? String,
                  let comps = URLComponents(string: link),
                  let skip = comps.queryItems?.first(where: { $0.name == "$skiptoken" })?.value else { return nil }
            return skip
        }()
        return (emails, next)
    }

    func fetchThread(conversationId: String) async throws -> [UnifiedEmail] {
        let token = try await validToken()
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        comps.queryItems = [
            .init(name: "$filter",  value: "conversationId eq '\(conversationId)'"),
            .init(name: "$select",  value: "id,conversationId,subject,from,toRecipients,bodyPreview,body,receivedDateTime,isRead,flag"),
            .init(name: "$orderby", value: "receivedDateTime asc")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json["value"] as? [[String: Any]] ?? []).compactMap { parseMessage($0) }
    }

    // ── Send ───────────────────────────────────────────────────────────

    func sendEmail(draft: EmailDraft) async throws {
        let token = try await validToken()
        var body: [String: Any] = [
            "message": [
                "subject": draft.subject,
                "body": ["contentType": "Text", "content": draft.body],
                "toRecipients": [["emailAddress": ["address": draft.to]]]
            ] as [String: Any],
            "saveToSentItems": true
        ]
        if let msgId = draft.replyToMessageId ?? draft.inReplyToThreadId {
            // replies require a different endpoint (individual message ID)
            // Outlook IDs are base64 strings that may contain '/', '+', '='.
            // These characters must be percent-encoded when used as a URL path segment.
            // .urlPathAllowed leaves '/' unencoded (it's a valid path separator),
            // so we explicitly remove '/', '+', and '=' from the allowed set.
            var segmentAllowed = CharacterSet.urlPathAllowed
            segmentAllowed.remove(charactersIn: "/+=")
            let encodedId = msgId.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? msgId
            var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(encodedId)/reply")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["comment": draft.body])
            let (replyData, replyResp) = try await URLSession.shared.data(for: req)
            if let http = replyResp as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                let detail = String(data: replyData, encoding: .utf8) ?? "no body"
                throw NSError(domain: "OutlookService", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Reply failed HTTP \(http.statusCode): \(detail)"])
            }
            return
        }
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw NSError(domain: "OutlookService", code: http.statusCode)
        }
    }

    func markRead(messageId: String) async throws {
        let token = try await validToken()
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(messageId)")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["isRead": true])
        _ = try await URLSession.shared.data(for: req)
    }

    // ── Parse ──────────────────────────────────────────────────────────

    private func parseMessage(_ msg: [String: Any]) -> UnifiedEmail? {
        guard let msgId = msg["id"] as? String else { return nil }
        let threadId = msg["conversationId"] as? String ?? msgId
        let subject  = msg["subject"] as? String ?? "(no subject)"
        let preview  = msg["bodyPreview"] as? String ?? ""
        let from     = (msg["from"] as? [String: Any]).flatMap { $0["emailAddress"] as? [String: Any] }
        let fromAddr = from?["address"] as? String ?? ""
        let fromName = from?["name"] as? String ?? fromAddr
        let isRead   = msg["isRead"] as? Bool ?? true
        let flagged  = ((msg["flag"] as? [String: Any])?["flagStatus"] as? String ?? "") == "flagged"
        let body     = (msg["body"] as? [String: Any])?["content"] as? String ?? preview
        let dateStr  = msg["receivedDateTime"] as? String ?? ""
        let date     = ISO8601DateFormatter().date(from: dateStr) ?? Date()
        let to       = (msg["toRecipients"] as? [[String: Any]] ?? []).compactMap { ($0["emailAddress"] as? [String: Any])?["address"] as? String }

        return UnifiedEmail(
            id: msgId, provider: .outlook, threadId: threadId,
            from: "\(fromName) <\(fromAddr)>", fromName: fromName,
            toRecipients: to,
            subject: subject, bodyPreview: preview, fullBody: stripHTML(body),
            date: date, isRead: isRead, isFlagged: flagged,
            priority: .normal, aiSummary: nil, aiPriorityReason: nil,
            labels: []
        )
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

    // ── ASWebAuthenticationPresentationContextProviding ────────────────
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // ── Keychain ───────────────────────────────────────────────────────
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

private struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}
