//
//  SkillsManager.swift
//  pa-agent
//
//  Skills framework — each skill can be enabled/disabled independently.
//  Skills are stored in UserDefaults (standard suite) so @AppStorage widgets
//  in any view can also observe them.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Skill definition

enum AgentSkill: String, CaseIterable, Identifiable {
    case email      = "email"
    case messaging  = "messaging"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email:     return "Email Assistant"
        case .messaging: return "Messaging & WhatsApp"
        }
    }

    var description: String {
        switch self {
        case .email:
            return "Connect Gmail or Outlook. The agent reads your inbox, triages priority emails, drafts AI-powered replies, and can send email on your behalf."
        case .messaging:
            return "Forward WhatsApp or iMessage conversations into Nexa via the iOS share sheet. The agent summarises threads, drafts replies, and creates follow-up tasks."
        }
    }

    var iconName: String {
        switch self {
        case .email:     return "envelope.fill"
        case .messaging: return "message.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .email:     return .blue
        case .messaging: return .green
        }
    }

    /// Whether enabling the skill for the first time should show a setup sheet
    var requiresSetup: Bool {
        switch self {
        case .email:     return true
        case .messaging: return false
        }
    }

    var userDefaultsKey: String { "skill_\(rawValue)_enabled" }
}

// MARK: - SkillsManager

final class SkillsManager: ObservableObject {

    static let shared = SkillsManager()
    private init() {}

    // Publish a value that increments whenever any skill changes,
    // so subscribers (e.g. ContentView) can rebuild the system prompt.
    @Published private(set) var changeToken: Int = 0

    // MARK: Public API

    func isEnabled(_ skill: AgentSkill) -> Bool {
        UserDefaults.standard.bool(forKey: skill.userDefaultsKey)
    }

    func setEnabled(_ skill: AgentSkill, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: skill.userDefaultsKey)
        DispatchQueue.main.async { self.changeToken += 1 }
    }

    func toggle(_ skill: AgentSkill) {
        setEnabled(skill, !isEnabled(skill))
    }

    // MARK: System-prompt capability block

    /// Returns extra lines to inject into the SUPPORTED CAPABILITIES section
    /// of the agent system prompt for every enabled skill.
    func extraCapabilities() -> String {
        var lines: [String] = []
        var index = 7   // base capabilities are 1-6

        if isEnabled(.email) {
            lines.append("\(index). Read & Triage Inbox (Action: 'readEmail'): Summarise unread emails, surface the most urgent ones, tell the user what needs attention.")
            index += 1
            lines.append("\(index). Draft Email Reply (Action: 'draftEmailReply'): Draft a reply to a specific email thread using AI, then let the user review and send.")
            index += 1
        }

        if isEnabled(.messaging) {
            lines.append("\(index). Process Shared Message (Action: 'processSharedMessage'): Analyse a forwarded WhatsApp/iMessage conversation, summarise it, draft a reply, or create a follow-up task.")
            index += 1
        }

        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    /// Returns a short context snippet summarising skill connectivity,
    /// for injection into the APP CONTEXT block.
    func contextSnippet(emailStore: EmailStore) -> String {
        var parts: [String] = []

        if isEnabled(.email) {
            let gmailConnected  = GmailService.shared.isSignedIn
            let outlookConnected = OutlookService.shared.isSignedIn
            let providers = [gmailConnected ? "Gmail" : nil, outlookConnected ? "Outlook" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            let unread = emailStore.emails.filter { !$0.isRead }.count
            let highPriority = emailStore.priorityQueue.prefix(5)
            var emailCtx = "EMAIL_SKILL: connected=[\(providers.isEmpty ? "none" : providers)], unread=\(unread)"
            if !highPriority.isEmpty {
                let summaries = highPriority.map { "• \($0.from): \($0.subject)" }.joined(separator: "\n")
                emailCtx += "\nHIGH_PRIORITY_EMAILS:\n\(summaries)"
            }
            parts.append(emailCtx)
        }

        if isEnabled(.messaging) {
            let pending = SharedContentProcessor.shared.pendingCount
            if pending > 0 {
                parts.append("MESSAGING_SKILL: \(pending) shared message(s) awaiting processing.")
            }
        }

        return parts.isEmpty ? "" : parts.joined(separator: "\n")
    }
}
