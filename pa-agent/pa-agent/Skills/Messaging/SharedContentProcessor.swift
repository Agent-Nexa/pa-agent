//
//  SharedContentProcessor.swift
//  pa-agent
//
//  Reads SharedItem payloads written by NexaShareExtension from the App Group
//  UserDefaults and routes each item through the AI pipeline.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class SharedContentProcessor: ObservableObject {

    static let shared = SharedContentProcessor()
    private init() {}

    private let suiteName = "group.z.Nexa"
    private let udKey     = "pendingSharedItems"

    // ── Published ──────────────────────────────────────────────────────
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var isProcessing: Bool = false

    // Processed items bubble up here so ContentView can present the right UI.
    @Published var pendingEmailDraft: EmailDraft?
    @Published var pendingMessageText: String?
    @Published var pendingTaskTitle: String?
    @Published var pendingAISummary: String?

    // ── Load pending count ─────────────────────────────────────────────

    func refreshPendingCount() {
        guard let ud = UserDefaults(suiteName: suiteName) else { return }
        let items = loadItems(ud: ud)
        pendingCount = items.filter { !$0.processed }.count
    }

    // ── Process all pending items ──────────────────────────────────────

    /// Call this when the app comes to foreground and Messaging skill is enabled.
    func processAll(
        intentService: IntentService,
        agentName: String,
        userName: String?,
        apiKey: String?,
        model: String?,
        useAzure: Bool,
        azureEndpoint: String?
    ) async {
        guard !isProcessing else { return }
        guard let ud = UserDefaults(suiteName: suiteName) else { return }
        var items = loadItems(ud: ud)
        let unprocessed = items.filter { !$0.processed }
        guard !unprocessed.isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        for i in 0..<items.count where !items[i].processed {
            let item = items[i]
            await processItem(item, intentService: intentService, agentName: agentName,
                              userName: userName, apiKey: apiKey, model: model,
                              useAzure: useAzure, azureEndpoint: azureEndpoint)
            items[i].processed = true
        }

        // Keep last 50, already-processed
        let kept = Array(items.suffix(50))
        saveItems(kept, ud: ud)
        pendingCount = 0
    }

    private func processItem(
        _ item: SharedItem,
        intentService: IntentService,
        agentName: String,
        userName: String?,
        apiKey: String?,
        model: String?,
        useAzure: Bool,
        azureEndpoint: String?
    ) async {
        // Build a prompt that tells the AI what the shared content is
        let prefix = "Shared from \(item.sourceDisplayName)"
        let note   = item.userNote.isEmpty ? "" : " — User note: \"\(item.userNote)\""
        let prompt = "\(prefix)\(note):\n\n\(item.content)"

        // Use IntentService to classify
        let result = await intentService.infer(
            from: prompt,
            imageDataURL: nil,
            apiKey: apiKey,
            model: model,
            useAzure: useAzure,
            azureEndpoint: azureEndpoint,
            userName: userName,
            agentName: agentName,
            appContext: nil,
            conversationHistory: []
        )

        guard let result else { return }

        switch result.action ?? "" {
        case "sendEmail":
            // Build an email draft pre-populated from the AI result
            pendingEmailDraft = EmailDraft(
                to:                  result.recipient ?? "",
                cc:                  "",
                subject:             result.subject ?? "Re: Shared conversation",
                body:                result.messageBody ?? "",
                inReplyToThreadId:   nil,
                provider:            GmailService.shared.isSignedIn ? .gmail : .outlook,
                isReply:             true
            )
        case "sendMessage":
            pendingMessageText = result.messageBody ?? ""
        case "task":
            pendingTaskTitle = result.title ?? item.content.prefix(80).description
        default:
            // answer / summarise — surface as a notification
            let summary = result.answer ?? result.title ?? "Processed shared content from \(item.sourceDisplayName)."
            pendingAISummary = summary
        }
    }

    // ── Persistence helpers ────────────────────────────────────────────

    private func loadItems(ud: UserDefaults) -> [SharedItem] {
        guard let data = ud.data(forKey: udKey),
              let items = try? JSONDecoder().decode([SharedItem].self, from: data) else { return [] }
        return items
    }

    private func saveItems(_ items: [SharedItem], ud: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        ud.set(data, forKey: udKey)
    }
}
