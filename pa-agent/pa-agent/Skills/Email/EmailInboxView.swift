//
//  EmailInboxView.swift
//  pa-agent
//
//  Triage inbox: fetches unread emails, runs AI triage, and shows ONLY emails
//  that need the user's attention. Ads and newsletters are filtered out.
//

import SwiftUI
import Combine

struct EmailInboxView: View {

    @StateObject private var emailStore      = EmailStore.shared
    @StateObject private var accountsManager = EmailAccountsManager.shared

    @State private var showAccounts: Bool = false

    // Sheet state owned here — attached to stable NavigationStack/List, not ForEach rows
    @State private var selectedEmail:  UnifiedEmail?
    @State private var showThread:     Bool = false
    @State private var draftForEmail:  UnifiedEmail?

    // Passed in from ContentView for AI triage calls
    var intentService:  IntentService
    var apiKey:         String?
    var model:          String?
    var useAzure:       Bool
    var azureEndpoint:  String?
    var agentName:      String
    var userName:       String?
    var accessToken:    String = ""

    var body: some View {
        NavigationStack {
            Group {
                if !accountsManager.hasAnyAccount {
                    noAccountView
                } else if emailStore.actionRequiredEmails.isEmpty && !emailStore.isTriaging {
                    allClearView
                } else {
                    triageList
                }
            }
            .navigationTitle("Action Required")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .refreshable { await startTriage() }
            .sheet(isPresented: $showAccounts) {
                NavigationStack {
                    AccountsListView(showDoneButton: true)
                        .navigationTitle("Email Accounts")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showThread) {
                if let email = selectedEmail {
                    NavigationStack {
                        EmailThreadView(
                            rootEmail: email,
                            intentService: intentService,
                            apiKey: apiKey,
                            model: model,
                            useAzure: useAzure,
                            azureEndpoint: azureEndpoint,
                            agentName: agentName,
                            userName: userName
                        )
                    }
                }
            }
            .sheet(item: $draftForEmail) { email in
                EmailDraftSheet(
                    initialDraft: EmailDraft(
                        to: email.from,
                        cc: "",
                        subject: email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)",
                        body: email.aiDraftBody ?? "",
                        inReplyToThreadId: email.threadId,
                        replyToMessageId: email.id,
                        provider: email.provider,
                        isReply: true
                    ),
                    thread: emailStore.thread(for: email),
                    intentService: intentService,
                    apiKey: apiKey,
                    model: model,
                    useAzure: useAzure,
                    azureEndpoint: azureEndpoint,
                    agentName: agentName,
                    userName: userName,
                    onSent: { sentBody in emailStore.markReplied(id: email.id, sentBody: sentBody) }
                )
            }
            // No auto-triage on view appear — the background monitor handles it hourly.
            // Pull-to-refresh and the toolbar button still allow manual on-demand triage.
        }
    }

    // MARK: - Triage list

    private var triageList: some View {
        List {
            if let err = emailStore.triageError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
            }
            if let progress = emailStore.triageProgress {
                Label(progress, systemImage: "wand.and.sparkles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            EmailTriageView(
                intentService: intentService,
                apiKey:        apiKey,
                model:         model,
                useAzure:      useAzure,
                azureEndpoint: azureEndpoint,
                agentName:     agentName,
                userName:      userName,
                accessToken:   accessToken,
                onOpenThread: { email in
                    selectedEmail = email
                    showThread = true
                },
                onReply: { email in
                    draftForEmail = email
                }
            )
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty states

    private var allClearView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.title2.bold())
            Text("No emails need your attention right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let err = emailStore.triageError {
                Text(err).font(.caption).foregroundStyle(.orange).padding(.top, 4)
            }
            Button("Check Again") { Task { await startTriage() } }
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noAccountView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.slash").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Email Account").font(.title3.bold())
            Text("Go to Settings → Skills → Email Assistant to connect Gmail or Outlook.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showAccounts = true } label: {
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .help("Manage Accounts")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if emailStore.isTriaging {
                ProgressView().scaleEffect(0.8)
            } else {
                Button { Task { await startTriage() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh & Re-triage")
            }
        }
    }

    // MARK: - Triage bridge

    /// Manual on-demand triage — triggered by pull-to-refresh or the toolbar button.
    private func startTriage() async {
        guard accountsManager.hasAnyAccount else { return }
        let ep    = azureEndpoint ?? UserDefaults.standard.string(forKey: AppConfig.Keys.azureEndpoint) ?? ""
        let key   = apiKey        ?? UserDefaults.standard.string(forKey: AppConfig.Keys.apiKey)        ?? ""
        let mdl   = model         ?? UserDefaults.standard.string(forKey: AppConfig.Keys.model)         ?? AppConfig.Defaults.model
        let azure = useAzure      || UserDefaults.standard.bool(forKey: AppConfig.Keys.useAzure)
        await emailStore.runTriage(ep: ep, key: key, mdl: mdl, azure: azure, token: accessToken)
    }

    // (kept for any internal EmailTriageView helpers that still call it)
    private func callAI(prompt: String) async throws -> String? {
        let ep    = azureEndpoint ?? UserDefaults.standard.string(forKey: AppConfig.Keys.azureEndpoint) ?? ""
        let key   = apiKey ?? UserDefaults.standard.string(forKey: AppConfig.Keys.apiKey) ?? ""
        let mdl   = model  ?? UserDefaults.standard.string(forKey: AppConfig.Keys.model) ?? AppConfig.Defaults.model
        let azure = useAzure || UserDefaults.standard.bool(forKey: AppConfig.Keys.useAzure)
        return try await EmailStore.callAIBackground(prompt: prompt, ep: ep, key: key, mdl: mdl, azure: azure, token: accessToken)
    }

}
