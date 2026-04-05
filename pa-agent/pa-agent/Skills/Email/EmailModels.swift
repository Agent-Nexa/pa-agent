//
//  EmailModels.swift
//  pa-agent
//
//  Unified email data models shared by GmailService, OutlookService and EmailStore.
//

import Foundation
import Combine

// MARK: - Provider

enum EmailProvider: String, Codable, Hashable {
    case gmail   = "gmail"
    case outlook = "outlook"

    var displayName: String {
        switch self {
        case .gmail:   return "Gmail"
        case .outlook: return "Outlook"
        }
    }

    var iconName: String {
        switch self {
        case .gmail:   return "envelope.fill"
        case .outlook: return "envelope.badge.fill"
        }
    }
}

// MARK: - Priority

enum EmailPriority: String, Codable, Comparable, Hashable {
    case high   = "high"
    case normal = "normal"
    case low    = "low"

    var sortOrder: Int {
        switch self { case .high: return 0; case .normal: return 1; case .low: return 2 }
    }

    static func < (lhs: EmailPriority, rhs: EmailPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var label: String {
        switch self { case .high: return "High"; case .normal: return "Normal"; case .low: return "Low" }
    }

    var color: String {          // used as SwiftUI Color name
        switch self { case .high: return "red"; case .normal: return "blue"; case .low: return "gray" }
    }
}

// MARK: - UnifiedEmail

struct UnifiedEmail: Identifiable, Codable, Hashable {
    var id: String                    // provider-scoped message/thread ID
    var provider: EmailProvider
    var threadId: String
    var from: String                  // "Display Name <addr@example.com>" or just addr
    var fromName: String              // extracted display name
    var toRecipients: [String]
    var subject: String
    var bodyPreview: String           // first ~200 chars, plain text
    var fullBody: String              // full decoded body (HTML stripped if possible)
    var date: Date
    var isRead: Bool
    var isFlagged: Bool
    var priority: EmailPriority
    var aiSummary: String?            // AI-generated one-liner
    var aiPriorityReason: String?     // why the AI assigned this priority
    var labels: [String]              // Gmail labels / Outlook categories

    // Convenience
    var fromInitials: String {
        let words = fromName.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(fromName.prefix(2)).uppercased()
    }

    var relativeDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
            return fmt.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}

// MARK: - EmailDraft

struct EmailDraft: Codable {
    var to: String
    var cc: String
    var subject: String
    var body: String
    var inReplyToThreadId: String?
    var provider: EmailProvider
    var isReply: Bool
}

// MARK: - SharedItem  (written by extension, read by main app)

struct SharedItem: Identifiable, Codable {
    var id: String = UUID().uuidString
    var content: String              // plain text extracted from share payload
    var contentType: String          // "text" | "image" | "url"
    var imageData: Data?             // if contentType == "image"
    var sourceBundleID: String       // e.g. "net.whatsapp.WhatsApp"
    var sourceAppName: String
    var userNote: String             // optional context the user typed in extension
    var timestamp: Date
    var processed: Bool = false

    var sourceDisplayName: String {
        if sourceBundleID.contains("whatsapp") { return "WhatsApp" }
        if sourceBundleID.contains("apple.mobilesms") { return "Messages" }
        if sourceBundleID.contains("telegram") { return "Telegram" }
        return sourceAppName.isEmpty ? "Unknown App" : sourceAppName
    }
}
