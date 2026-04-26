//
//  MorningBriefingView.swift
//  pa-agent
//
//  Daily morning briefing sheet: today's tasks, overdue tasks,
//  and pre-drafted emails / messages for action tasks.
//

import SwiftUI
import MessageUI

// MARK: - Notification name

extension Notification.Name {
    static let nexaMorningBriefingTapped = Notification.Name("nexaMorningBriefingTapped")
}

// MARK: - MorningBriefingView

struct MorningBriefingView: View {

    // All tasks bound from ContentView so completions persist
    @Binding var tasks: [TaskItem]
    @Environment(\.dismiss) private var dismiss

    // AppStorage keys mirroring SettingsView / other views
    @AppStorage(AppConfig.Keys.agentName)   private var agentName:     String = AppConfig.Defaults.agentName
    @AppStorage("USER_NAME")                private var userName:       String = ""
    @AppStorage(AppConfig.Keys.apiKey)      private var apiKey:         String = ""
    @AppStorage(AppConfig.Keys.model)       private var model:          String = AppConfig.Defaults.model
    @AppStorage("OPENAI_USE_AZURE")         private var useAzure:       Bool   = true
    @AppStorage(AppConfig.Keys.azureEndpoint) private var azureEndpoint: String = ""

    // Email draft sheet state
    @State private var emailDraftTask:   TaskItem?   = nil
    @State private var showEmailDraft:   Bool        = false

    // Message compose state
    @State private var messageTask:      TaskItem?   = nil
    @State private var showMessageSheet: Bool        = false

    // MARK: Derived lists

    private var overdueTasks: [TaskItem] {
        tasks.filter { $0.status == .open && $0.isOverdue() }
             .sorted { $0.dueDate < $1.dueDate }
    }

    private var todayTasks: [TaskItem] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { return [] }
        return tasks.filter {
            $0.status == .open
            && !$0.isOverdue()
            && $0.dueDate >= today
            && $0.dueDate < tomorrow
        }
        .sorted { $0.dueDate < $1.dueDate }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            List {
                greetingSection
                if !overdueTasks.isEmpty { overdueSection }
                if !todayTasks.isEmpty   { todaySection }
                if overdueTasks.isEmpty && todayTasks.isEmpty { emptySection }
            }
            .navigationTitle("Morning Briefing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Email draft sheet
            .sheet(isPresented: $showEmailDraft) {
                if let task = emailDraftTask,
                   let payload = task.actionPayload {
                    let draft = EmailDraft(
                        to:      payload.recipient,
                        cc:      "",
                        subject: payload.subject ?? task.title,
                        body:    payload.body ?? "",
                        inReplyToThreadId: nil,
                        provider: .gmail,
                        isReply: false
                    )
                    EmailDraftSheet(
                        initialDraft:  draft,
                        thread:        [],
                        intentService: IntentService(),
                        apiKey:        apiKey.isEmpty ? nil : apiKey,
                        model:         model.isEmpty  ? nil : model,
                        useAzure:      useAzure,
                        azureEndpoint: azureEndpoint.isEmpty ? nil : azureEndpoint,
                        agentName:     agentName,
                        userName:      userName.isEmpty ? nil : userName
                    )
                }
            }
            // Message compose sheet
            .sheet(isPresented: $showMessageSheet) {
                if let task = messageTask,
                   let payload = task.actionPayload,
                   MFMessageComposeViewController.canSendText() {
                    MessageComposeView(
                        recipient: payload.recipient,
                        body: payload.body ?? ""
                    )
                } else {
                    messageFallbackView
                }
            }
        }
    }

    // MARK: Sections

    private var greetingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                let greeting = morningGreeting()
                Text(greeting)
                    .font(.headline)
                Text(formattedToday())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var overdueSection: some View {
        Section {
            ForEach(overdueTasks) { task in
                taskRow(task, isOverdue: true)
            }
        } header: {
            Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var todaySection: some View {
        Section {
            ForEach(todayTasks) { task in
                taskRow(task, isOverdue: false)
            }
        } header: {
            Label("Today", systemImage: "calendar")
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("All clear for today!")
                    .font(.headline)
                Text("No tasks due or overdue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
        }
    }

    // MARK: Task Row

    @ViewBuilder
    private func taskRow(_ task: TaskItem, isOverdue: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Priority dot
                Circle()
                    .fill(priorityColor(task.priority))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.body)
                        .foregroundStyle(isOverdue ? .red : .primary)

                    HStack(spacing: 8) {
                        if isOverdue {
                            Text("Due \(relativeDate(task.dueDate))")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(formattedTime(task.dueDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !task.tag.isEmpty && task.tag != "General" {
                            Text(task.tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()

                // Complete button
                Button {
                    markComplete(task)
                } label: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            }

            // Action draft buttons
            if let payload = task.actionPayload {
                let type = payload.type.lowercased()
                if type == "sendemail" || type == "email" || type == "draftEmailReply".lowercased() {
                    Button {
                        emailDraftTask = task
                        showEmailDraft = true
                    } label: {
                        Label("Draft Email to \(payload.recipient)", systemImage: "envelope.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .padding(.leading, 16)
                } else if type == "sendmessage" || type == "message" {
                    Button {
                        messageTask = task
                        showMessageSheet = true
                    } label: {
                        Label("Draft Message to \(payload.recipient)", systemImage: "message.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Fallback when MFMessageCompose unavailable (Simulator)

    private var messageFallbackView: some View {
        NavigationStack {
            if let task = messageTask, let payload = task.actionPayload {
                Form {
                    Section("To") { Text(payload.recipient) }
                    Section("Message") { Text(payload.body ?? "").font(.body) }
                }
                .navigationTitle("Message Draft")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showMessageSheet = false }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func markComplete(_ task: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].status = .completed
            tasks[idx].isDone = true
            tasks[idx].completedAt = Date()
            saveTasks()
        }
    }

    private func saveTasks() {
        if let encoded = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(encoded, forKey: "tasks")
        }
    }

    // MARK: Helpers

    private func morningGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = userName.isEmpty ? "" : ", \(userName)"
        switch hour {
        case 0..<12: return "Good morning\(name)! 🌅"
        case 12..<17: return "Good afternoon\(name)!"
        default:       return "Good evening\(name)!"
        }
    }

    private func formattedToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 1: return .red
        case 2: return .orange
        default: return .gray
        }
    }
}

// MARK: - Message Compose Bridge

struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
        }
    }
}
