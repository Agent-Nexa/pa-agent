//
//  EmailDraftSheet.swift
//  pa-agent
//
//  Editable email draft sheet, pre-populated by AI.
//  User can edit, regenerate, send, or save as a task.
//

import SwiftUI
import Combine

struct EmailDraftSheet: View {

    let initialDraft:  EmailDraft
    let thread:        [UnifiedEmail]
    let intentService: IntentService
    let apiKey:        String?
    let model:         String?
    let useAzure:      Bool
    let azureEndpoint: String?
    let agentName:     String
    let userName:      String?

    @Environment(\.dismiss) private var dismiss

    @State private var to:      String
    @State private var cc:      String
    @State private var subject: String
    @State private var messageBody: String
    @State private var isSending      = false
    @State private var isRegenerating = false
    @State private var sendResult:    SendResult?
    @State private var showConfirm    = false
    @State private var taskSaved      = false

    enum SendResult { case success, failure(String) }

    init(initialDraft: EmailDraft, thread: [UnifiedEmail],
         intentService: IntentService, apiKey: String?, model: String?,
         useAzure: Bool, azureEndpoint: String?, agentName: String, userName: String?) {
        self.initialDraft  = initialDraft
        self.thread        = thread
        self.intentService = intentService
        self.apiKey        = apiKey
        self.model         = model
        self.useAzure      = useAzure
        self.azureEndpoint = azureEndpoint
        self.agentName     = agentName
        self.userName      = userName
        _to      = State(initialValue: initialDraft.to)
        _cc      = State(initialValue: initialDraft.cc)
        _subject = State(initialValue: initialDraft.subject)
        _messageBody = State(initialValue: initialDraft.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Recipients
                Section("Recipients") {
                    HStack(spacing: 4) {
                        Text("To").font(.footnote).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        TextField("To", text: $to)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                    }
                    HStack(spacing: 4) {
                        Text("Cc").font(.footnote).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        TextField("Cc (optional)", text: $cc)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                    }
                    HStack(spacing: 4) {
                        Text("Sub").font(.footnote).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        TextField("Subject", text: $subject)
                    }
                }

                // Body
                Section("Message") {
                    TextEditor(text: $messageBody)
                        .font(.body)
                        .frame(minHeight: 220)
                }

                // Provider indicator
                Section {
                    Label("Sending via \(initialDraft.provider.displayName)", systemImage: initialDraft.provider.iconName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                if messageBody.isEmpty {
                    Section {
                        Button {
                            Task { await regenerateDraft() }
                        } label: {
                            Label(isRegenerating ? "Generating…" : "Generate with AI", systemImage: "sparkles")
                        }
                        .disabled(isRegenerating)
                    }
                }
            }
            .navigationTitle(initialDraft.isReply ? "Reply" : "New Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Regenerate
                    Button {
                        Task { await regenerateDraft() }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .disabled(isRegenerating)
                    .help("Regenerate with AI")

                    // Send
                    Button {
                        showConfirm = true
                    } label: {
                        if isSending {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Send", systemImage: "paperplane.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .disabled(to.isEmpty || subject.isEmpty || messageBody.isEmpty || isSending)
                    .fontWeight(.semibold)
                }
            }
            .alert("Send Email?", isPresented: $showConfirm) {
                Button("Send", role: .none) { Task { await sendEmail() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Send to \(to)?")
            }
            .alert(resultTitle, isPresented: Binding(get: { sendResult != nil }, set: { if !$0 { sendResult = nil } })) {
                Button("OK") { if case .success = sendResult { dismiss() } }
            } message: {
                Text(resultMessage)
            }
            .task { if messageBody.isEmpty { await regenerateDraft() } }
        }
    }

    // MARK: - AI regenerate

    private func regenerateDraft() async {
        isRegenerating = true
        defer { isRegenerating = false }

        let threadContext = thread.isEmpty ? "" : "\n\nThread context:\n" + thread.map {
            "From: \($0.from)\n\($0.fullBody.isEmpty ? $0.bodyPreview : String($0.fullBody.prefix(500)))"
        }.joined(separator: "\n---\n")
        let prompt = """
        Draft a professional reply email body.
        From: \(userName ?? "me")
        To: \(to)
        Subject: \(subject)
        \(threadContext)
        Respond ONLY with the email body text. No subject, no greeting header, no JSON.
        """

        let result = await intentService.infer(
            from: prompt, imageDataURL: nil,
            apiKey: apiKey, model: model, useAzure: useAzure, azureEndpoint: azureEndpoint,
            userName: userName, agentName: agentName, appContext: nil, conversationHistory: []
        )
        let generated = result?.answer ?? result?.messageBody ?? ""
        if !generated.isEmpty { messageBody = generated }
    }

    // MARK: - Send

    private func sendEmail() async {
        isSending = true
        defer { isSending = false }

        let draft = EmailDraft(
            to: to, cc: cc, subject: subject, body: messageBody,
            inReplyToThreadId: initialDraft.inReplyToThreadId,
            provider: initialDraft.provider, isReply: initialDraft.isReply
        )
        do {
            let mgr = EmailAccountsManager.shared
            // Find first account for the draft's provider
            if let account = mgr.accounts(for: draft.provider).first {
                if draft.provider == .gmail {
                    try await mgr.gmailSend(account: account, draft: draft)
                } else {
                    try await mgr.outlookSend(account: account, draft: draft)
                }
            } else {
                // Legacy fallback to singletons
                if draft.provider == .gmail {
                    try await GmailService.shared.sendEmail(draft: draft)
                } else {
                    try await OutlookService.shared.sendEmail(draft: draft)
                }
            }
            sendResult = .success
        } catch {
            sendResult = .failure(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private var resultTitle: String {
        switch sendResult {
        case .success:    return "Email Sent"
        case .failure:    return "Send Failed"
        case .none:       return ""
        }
    }

    private var resultMessage: String {
        switch sendResult {
        case .success:        return "Your email was sent successfully."
        case .failure(let e): return e
        case .none:           return ""
        }
    }
}
