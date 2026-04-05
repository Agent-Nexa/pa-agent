//
//  EmailThreadView.swift
//  pa-agent
//
//  Full email thread reader with AI actions: Summarize, Draft Reply, Save as Task.
//

import SwiftUI
import Combine

struct EmailThreadView: View {

    let rootEmail:     UnifiedEmail
    let intentService: IntentService
    let apiKey:        String?
    let model:         String?
    let useAzure:      Bool
    let azureEndpoint: String?
    let agentName:     String
    let userName:      String?

    @StateObject private var emailStore = EmailStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showDraft    = false
    @State private var draftEmail: EmailDraft?
    @State private var summary:     String?
    @State private var showSummary  = false
    @State private var isSummarizing = false
    @State private var isDrafting   = false
    @State private var taskCreated  = false

    // These are passed up to ContentView via a callback if needed — or handled here
    var onSaveAsTask: ((String) -> Void)? = nil

    private var thread: [UnifiedEmail] {
        emailStore.thread(for: rootEmail)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Subject + participants bar
                VStack(alignment: .leading, spacing: 4) {
                    Text(rootEmail.subject)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(thread.count) message\(thread.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))

                Divider()

                // Message list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(thread) { message in
                            messageCard(message)
                        }
                    }
                    .padding()
                }

                Divider()

                // Action bar
                actionBar
                    .padding()
                    .background(Color(.systemBackground))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showDraft) {
                if let d = draftEmail {
                    EmailDraftSheet(
                        initialDraft:  d,
                        thread:        thread,
                        intentService: intentService,
                        apiKey:        apiKey,
                        model:         model,
                        useAzure:      useAzure,
                        azureEndpoint: azureEndpoint,
                        agentName:     agentName,
                        userName:      userName
                    )
                }
            }
            .alert("Summary", isPresented: $showSummary, presenting: summary) { _ in
                Button("OK", role: .cancel) {}
            } message: { s in
                Text(s)
            }
        }
    }

    // MARK: - Message card

    private func messageCard(_ message: UnifiedEmail) -> some View {
        let isSelf = message.from.localizedCaseInsensitiveContains(GmailService.shared.connectedEmail) ||
                     message.from.localizedCaseInsensitiveContains(OutlookService.shared.connectedEmail)
        return VStack(alignment: isSelf ? .trailing : .leading, spacing: 4) {
            HStack {
                if isSelf { Spacer() }
                Text(message.fromName.isEmpty ? message.from : message.fromName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !isSelf { Spacer() }
                Text(message.relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(message.fullBody.isEmpty ? message.bodyPreview : message.fullBody)
                .font(.subheadline)
                .padding(12)
                .background(isSelf ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: isSelf ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: isSelf ? .trailing : .leading)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            // Summarize
            Button {
                Task { await summarizeThread() }
            } label: {
                Label(isSummarizing ? "Summarizing…" : "Summarize", systemImage: "text.quote")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(isSummarizing)

            // Draft Reply
            Button {
                Task { await draftReply() }
            } label: {
                Label(isDrafting ? "Drafting…" : "Draft Reply", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDrafting)

            // Save as Task
            Button {
                guard !taskCreated else { return }
                onSaveAsTask?(rootEmail.subject)
                taskCreated = true
            } label: {
                Label(taskCreated ? "Saved" : "Task", systemImage: taskCreated ? "checkmark" : "plus.circle")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(taskCreated ? .green : .primary)
        }
    }

    // MARK: - AI actions

    private func summarizeThread() async {
        isSummarizing = true
        defer { isSummarizing = false }

        let fullText = thread.map { "From: \($0.from)\n\($0.fullBody.isEmpty ? $0.bodyPreview : $0.fullBody)" }.joined(separator: "\n\n---\n\n")
        let prompt = "Summarise this email thread in 3-5 sentences. Be concise and highlight any required actions or decisions.\n\nThread:\n\(fullText)"

        let result = await intentService.infer(
            from: prompt, imageDataURL: nil,
            apiKey: apiKey, model: model, useAzure: useAzure, azureEndpoint: azureEndpoint,
            userName: userName, agentName: agentName, appContext: nil, conversationHistory: []
        )
        summary    = result?.answer ?? "Could not generate a summary."
        showSummary = true
    }

    private func draftReply() async {
        isDrafting = true
        defer { isDrafting = false }

        let fullText = thread.map { "From: \($0.from)\n\($0.fullBody.isEmpty ? $0.bodyPreview : $0.fullBody)" }.joined(separator: "\n\n---\n\n")
        let latestSender = thread.last?.fromName ?? thread.last?.from ?? ""
        let prompt = """
        Draft a professional, concise reply to the following email thread.
        The reply is from \(userName ?? "me") to \(latestSender).
        Respond ONLY with the reply body (no subject line, no greeting header).

        Thread:
        \(fullText)
        """

        let result = await intentService.infer(
            from: prompt, imageDataURL: nil,
            apiKey: apiKey, model: model, useAzure: useAzure, azureEndpoint: azureEndpoint,
            userName: userName, agentName: agentName, appContext: nil, conversationHistory: []
        )

        draftEmail = EmailDraft(
            to:                  (thread.last?.from ?? rootEmail.from),
            cc:                  "",
            subject:             rootEmail.subject.hasPrefix("Re:") ? rootEmail.subject : "Re: \(rootEmail.subject)",
            body:                result?.answer ?? result?.messageBody ?? "",
            inReplyToThreadId:   rootEmail.threadId,
            provider:            rootEmail.provider,
            isReply:             true
        )
        showDraft = true
    }
}
