//
//  EmailInboxView.swift
//  pa-agent
//
//  Unified inbox showing Gmail + Outlook emails, sorted by AI-assigned priority.
//

import SwiftUI
import Combine

struct EmailInboxView: View {

    @StateObject private var emailStore     = EmailStore.shared
    @StateObject private var gmailService   = GmailService.shared
    @StateObject private var outlookService = OutlookService.shared

    @State private var selectedEmail:     UnifiedEmail?
    @State private var showThread:        Bool = false
    @State private var draftForEmail:     UnifiedEmail?
    @State private var showDraft:         Bool = false
    @State private var taskFromEmail:     UnifiedEmail?
    @State private var filterPriority:    EmailPriority? = nil

    // Passed in from ContentView for AI triage calls
    var intentService:  IntentService
    var apiKey:         String?
    var model:          String?
    var useAzure:       Bool
    var azureEndpoint:  String?
    var agentName:      String
    var userName:       String?

    var body: some View {
        NavigationStack {
            Group {
                if !gmailService.isSignedIn && !outlookService.isSignedIn {
                    noAccountView
                } else if emailStore.emails.isEmpty && !emailStore.isRefreshing {
                    emptyView
                } else {
                    inboxList
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .refreshable { await emailStore.refresh() }
            .sheet(isPresented: $showThread) {
                if let email = selectedEmail {
                    EmailThreadView(
                        rootEmail:     email,
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
            .sheet(isPresented: $showDraft) {
                if let email = draftForEmail {
                    EmailDraftSheet(
                        initialDraft: EmailDraft(
                            to: email.from,
                            cc: "",
                            subject: email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)",
                            body: "",
                            inReplyToThreadId: email.threadId,
                            provider: email.provider,
                            isReply: true
                        ),
                        thread:       emailStore.thread(for: email),
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
            .task {
                if emailStore.emails.isEmpty { await emailStore.refresh() }
            }
        }
    }

    // MARK: - Inbox list

    private var inboxList: some View {
        List {
            if emailStore.isRefreshing && emailStore.emails.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity)
            }

            // Priority filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(nil, label: "All")
                    filterChip(.high, label: "High")
                    filterChip(.normal, label: "Normal")
                    filterChip(.low, label: "Low")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            let grouped = groupedEmails
            ForEach(grouped.keys.sorted { $0.sortOrder < $1.sortOrder }, id: \.self) { priority in
                Section(header: priorityHeader(priority)) {
                    ForEach(grouped[priority] ?? []) { email in
                        emailRow(email)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { emailStore.markRead(id: email.id) } label: {
                                    Label("Read", systemImage: "envelope.open")
                                }.tint(.blue)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button { emailStore.flagEmail(id: email.id) } label: {
                                    Label(email.isFlagged ? "Unflag" : "Flag", systemImage: email.isFlagged ? "flag.slash" : "flag.fill")
                                }.tint(.orange)

                                Button {
                                    draftForEmail = email
                                    showDraft = true
                                } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                                }.tint(.green)
                            }
                            .onTapGesture {
                                selectedEmail = email
                                showThread = true
                                if !email.isRead { emailStore.markRead(id: email.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Email row

    private func emailRow(_ email: UnifiedEmail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread dot
            Circle()
                .fill(email.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            // Avatar
            ZStack {
                Circle()
                    .fill(priorityColor(email.priority).opacity(0.18))
                    .frame(width: 40, height: 40)
                Text(email.fromInitials)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(priorityColor(email.priority))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(email.fromName.isEmpty ? email.from : email.fromName)
                        .font(.subheadline.weight(email.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(email.relativeDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if email.isFlagged {
                        Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(email.subject)
                    .font(.footnote.weight(email.isRead ? .regular : .medium))
                    .lineLimit(1)
                Text(email.aiSummary ?? email.bodyPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Priority badge
                HStack(spacing: 4) {
                    priorityBadge(email.priority)
                    providerBadge(email.provider)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Headers & badges

    private func priorityHeader(_ priority: EmailPriority) -> some View {
        HStack(spacing: 6) {
            Circle().fill(priorityColor(priority)).frame(width: 8, height: 8)
            Text(priority.label + " Priority")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func priorityBadge(_ priority: EmailPriority) -> some View {
        Text(priority.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor(priority).opacity(0.12))
            .foregroundStyle(priorityColor(priority))
            .clipShape(Capsule())
    }

    private func providerBadge(_ provider: EmailProvider) -> some View {
        Label(provider.displayName, systemImage: provider.iconName)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private func priorityColor(_ p: EmailPriority) -> Color {
        switch p { case .high: return .red; case .normal: return .blue; case .low: return .gray }
    }

    // MARK: - Filter chips

    private func filterChip(_ priority: EmailPriority?, label: String) -> some View {
        Button { filterPriority = priority } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(filterPriority == priority ? Color.blue : Color.secondary.opacity(0.15))
                .foregroundStyle(filterPriority == priority ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    await emailStore.refresh()
                    await triageEmails()
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .help("AI Triage")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if emailStore.isRefreshing { ProgressView().scaleEffect(0.8) }
        }
    }

    // MARK: - Grouped emails

    private var groupedEmails: [EmailPriority: [UnifiedEmail]] {
        let source = filterPriority == nil ? emailStore.emails : emailStore.emails.filter { $0.priority == filterPriority }
        return Dictionary(grouping: source.sorted { $0.date > $1.date }, by: \.priority)
    }

    // MARK: - AI Triage

    private func triageEmails() async {
        let batch = emailStore.emails.filter { $0.aiSummary == nil }.prefix(20)
        guard !batch.isEmpty else { return }

        let prompt = """
        Triage these emails. For each, respond with a JSON array where each object has:
        "id": email id,
        "priority": "high"|"normal"|"low",
        "reason": one-line reason,
        "summary": one-sentence plain-English summary of the email.

        Emails:
        \(batch.map { "id:\($0.id) from:\($0.from) subject:\($0.subject) preview:\($0.bodyPreview.prefix(100))" }.joined(separator: "\n"))

        Respond ONLY with the JSON array.
        """

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

        // Parse triage from result.answer plain text
        guard let raw = result?.answer,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for item in arr {
            guard let id = item["id"] as? String,
                  let pStr = item["priority"] as? String,
                  let priority = EmailPriority(rawValue: pStr) else { continue }
            let reason  = item["reason"]  as? String
            let summary = item["summary"] as? String
            emailStore.updatePriority(id: id, priority: priority, reason: reason, summary: summary)
        }
    }

    // MARK: - Empty / no-account states

    private var noAccountView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.slash").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Email Account").font(.title3.bold())
            Text("Go to Settings → Skills → Email Assistant to connect Gmail or Outlook.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Inbox is empty").font(.title3.bold())
            Text("Pull down to refresh.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
