//
//  EmailTriageView.swift
//  pa-agent
//
//  Displays emails that the AI flagged as needing action.
//  Each row has quick action chips: AI Reply, Schedule Meeting, Summarise.
//  Swipe-right dismisses an email from the triage queue.
//

import SwiftUI

struct EmailTriageView: View {

    @StateObject private var emailStore = EmailStore.shared

    // Passed in from EmailInboxView
    var intentService:  IntentService
    var apiKey:         String?
    var model:          String?
    var useAzure:       Bool
    var azureEndpoint:  String?
    var agentName:      String
    var userName:       String?
    var accessToken:    String = ""

    // Callbacks — sheets are owned by EmailInboxView (stable parent) to prevent
    // SwiftUI from recycling ForEach rows and immediately dismissing attached sheets.
    var onOpenThread: (UnifiedEmail) -> Void = { _ in }
    var onReply:      (UnifiedEmail) -> Void = { _ in }

    // Local state
    @State private var summaryLoading:      Set<String> = []
    @State private var schedulingInProgress: Set<String> = []
    @State private var errorMessage:        String?

    var body: some View {
        let actionEmails = emailStore.actionRequiredEmails
        if actionEmails.isEmpty {
            allClearView
        } else {
            triageList(actionEmails)
        }
    }

    // MARK: - All clear

    private var allClearView: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("All clear — no emails need action")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Triage list

    private func triageList(_ emails: [UnifiedEmail]) -> some View {
        ForEach(emails) { email in
            triageRow(email)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        emailStore.markTriaged(id: email.id, isActionRequired: false)
                    } label: {
                        Label("Done", systemImage: "checkmark.circle.fill")
                    }
                    .tint(.green)
                }
                .onTapGesture {
                    if !email.isRead { emailStore.markRead(id: email.id) }
                    onOpenThread(email)
                }
        }
    }

    // MARK: - Row

    private func triageRow(_ email: UnifiedEmail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .top, spacing: 10) {
                // Unread dot
                Circle()
                    .fill(email.isRead ? Color.clear : Color.orange)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(email.fromName.isEmpty ? email.from : email.fromName)
                            .font(.subheadline.weight(email.isRead ? .regular : .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(email.relativeDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(email.subject)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    if let summary = email.aiSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(email.bodyPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            // Action chips
            HStack(spacing: 8) {
                if email.requiresReply {
                    actionChip(
                        icon: "arrowshape.turn.up.left.fill",
                        label: email.aiDraftBody != nil ? "Review Reply" : "AI Reply",
                        tint: .blue
                    ) {
                        prepareAIReply(for: email)
                    }
                }

                // Schedule chip — shows spinner while loading, per-event badges after
                if schedulingInProgress.contains(email.id) {
                    ProgressView()
                        .scaleEffect(0.75)
                        .padding(.horizontal, 4)
                } else if !email.scheduledEvents.isEmpty {
                    scheduledBadges(for: email)
                } else {
                    actionChip(
                        icon: "calendar.badge.plus",
                        label: "Schedule",
                        tint: .purple
                    ) {
                        Task { await scheduleMeeting(for: email) }
                    }
                }

                if summaryLoading.contains(email.id) {
                    ProgressView().scaleEffect(0.7)
                } else {
                    actionChip(
                        icon: "sparkles",
                        label: "Summarise",
                        tint: .orange
                    ) {
                        Task { await fetchSummary(for: email) }
                    }
                }

                Spacer()

                // Dismiss chip
                Button {
                    emailStore.markTriaged(id: email.id, isActionRequired: false)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Scheduled badges

    private func scheduledBadges(for email: UnifiedEmail) -> some View {
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f
        }()
        return ForEach(email.scheduledEvents) { event in
            HStack(spacing: 3) {
                Text("\u{1F4C5} \(fmt.string(from: event.date))")  // 📅
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                Button {
                    // Delete task from ContentView
                    NotificationCenter.default.post(
                        name: .nexaDeleteTask,
                        object: nil,
                        userInfo: ["taskId": event.taskId.uuidString]
                    )
                    // Remove badge from email
                    emailStore.removeScheduledEvent(emailId: email.id, taskId: event.taskId)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.purple.opacity(0.10))
            .clipShape(Capsule())
        }
    }

    // MARK: - Action chip

    private func actionChip(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint.opacity(0.12))
                .foregroundStyle(tint)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func prepareAIReply(for email: UnifiedEmail) {
        onReply(email)
    }

    private func scheduleMeeting(for email: UnifiedEmail) async {
        guard !schedulingInProgress.contains(email.id) else { return }
        schedulingInProgress.insert(email.id)
        defer { schedulingInProgress.remove(email.id) }

        let azure = useAzure || UserDefaults.standard.bool(forKey: AppConfig.Keys.useAzure)
        let key   = apiKey ?? UserDefaults.standard.string(forKey: AppConfig.Keys.apiKey) ?? ""
        guard azure || !key.isEmpty else { return }

        let todayISO = ISO8601DateFormatter().string(from: Date())
        let prompt = """
        Extract ALL distinct events, meetings, and deadlines from this email.
        Return JSON:
        {
          "events": [
            {"title": "short event title", "date": "YYYY-MM-DD (the actual event date, NOT today \(todayISO))", "time": "HH:MM 24h or empty string"}
          ],
          "replyBody": "one short reply acknowledging all events/deadlines, or empty string if none"
        }
        Rules:
        - Include every distinct event or deadline mentioned.
        - "date" must be the event date from the email, NOT today.
        - If no date is mentioned for an event, use an empty string for "date".
        - If no events are found, return {"events": [], "replyBody": ""}.

        Email from: \(email.from)
        Subject: \(email.subject)
        Body: \(email.fullBody.prefix(800))

        Respond ONLY with valid JSON.
        """

        do {
            let result = try await callAI(prompt: prompt)

            // Extract outermost JSON object (strip markdown fences if present)
            let jsonString: String
            if let start = result.range(of: "{"),
               let end   = result.range(of: "}", options: .backwards),
               start.lowerBound <= end.lowerBound {
                jsonString = String(result[start.lowerBound...end.upperBound])
            } else {
                jsonString = result
            }
            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

            let rawEvents = json["events"]    as? [[String: Any]] ?? []
            let replyBody = json["replyBody"] as? String ?? ""

            var scheduledEvents: [ScheduledEmailEvent] = []

            for rawEvent in rawEvents {
                let title     = rawEvent["title"] as? String ?? "Meeting re: \(email.subject)"
                let dateStr   = rawEvent["date"]  as? String ?? ""
                let eventDate = parseEmailTaskDate(dateStr) ?? Date().addingTimeInterval(60 * 60 * 24)

                let task = TaskItem(
                    title:     title,
                    tag:       "Email",
                    startDate: eventDate,
                    dueDate:   eventDate,
                    priority:  1
                )

                // Silently add to ContentView's task list — no confirmation alert
                if let taskData = try? JSONEncoder().encode(task) {
                    NotificationCenter.default.post(
                        name: .nexaAddTaskSilent,
                        object: nil,
                        userInfo: ["taskData": taskData]
                    )
                }

                scheduledEvents.append(ScheduledEmailEvent(taskId: task.id, title: title, date: eventDate))
            }

            // Attach badges to the email row (email stays in triage list)
            if !scheduledEvents.isEmpty {
                emailStore.addScheduledEvents(id: email.id, events: scheduledEvents)
            }

            // Open a reply draft if the AI generated one
            if !replyBody.isEmpty {
                let draft = EmailDraft(
                    to: email.from,
                    cc: "",
                    subject: "Re: \(email.subject)",
                    body: replyBody,
                    inReplyToThreadId: email.threadId,
                    replyToMessageId: email.id,
                    provider: email.provider,
                    isReply: true
                )
                NotificationCenter.default.post(
                    name: .nexaOpenEmailDraft,
                    object: nil,
                    userInfo: ["draft": draft]
                )
            }
        } catch {
            print("[EmailTriageView] Schedule error: \(error)")
        }
    }

    /// Parse a date string returned by the schedule AI into a concrete Date.
    private func parseEmailTaskDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date()
        if s == "today"    { return now }
        if s == "tomorrow" { return cal.date(byAdding: .day, value: 1, to: now) }
        let fmts = ["yyyy-MM-dd", "MM/dd/yyyy", "dd MMM yyyy", "MMM dd, yyyy",
                    "MMMM dd, yyyy", "MMMM d, yyyy", "MMM d yyyy"]
        let df = DateFormatter()
        df.locale   = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        for fmt in fmts {
            df.dateFormat = fmt
            if let d = df.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        }
        return nil
    }

    private func fetchSummary(for email: UnifiedEmail) async {
        guard !summaryLoading.contains(email.id) else { return }
        summaryLoading.insert(email.id)
        defer { summaryLoading.remove(email.id) }

        let body = email.fullBody.isEmpty ? email.bodyPreview : email.fullBody
        let prompt = """
        Summarise this email in one clear sentence. Be specific about what is being asked or shared.

        From: \(email.from)
        Subject: \(email.subject)
        Body: \(body.prefix(800))
        """

        if let summary = try? await callAI(prompt: prompt) {
            let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            emailStore.updatePriority(id: email.id, priority: email.priority, summary: cleaned)
        }
    }

    // MARK: - Direct chat completions helper

    private func callAI(prompt: String) async throws -> String {
        let ep    = azureEndpoint ?? UserDefaults.standard.string(forKey: AppConfig.Keys.azureEndpoint) ?? ""
        let key   = apiKey ?? UserDefaults.standard.string(forKey: AppConfig.Keys.apiKey) ?? ""
        let mdl   = model  ?? UserDefaults.standard.string(forKey: AppConfig.Keys.model) ?? AppConfig.Defaults.model
        let azure = useAzure || UserDefaults.standard.bool(forKey: AppConfig.Keys.useAzure)

        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]

        if azure && !ep.isEmpty {
            guard let base = URL(string: ep), let host = base.host,
                  let u = URL(string: "\(base.scheme ?? "https")://\(host)/openai/models/chat/completions?api-version=2024-05-01-preview")
            else { throw URLError(.badURL) }
            url = u
            if !key.isEmpty        { headers["api-key"]      = key }
            if !accessToken.isEmpty { headers["X-User-Token"] = accessToken }
        } else {
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            guard !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
            headers["Authorization"] = "Bearer \(key)"
        }

        let body: [String: Any] = [
            "model":           mdl,
            "messages":        [["role": "user", "content": prompt]],
            "temperature":     0
            // max_tokens omitted — gpt-5.2/o1 on Azure do not support it
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody   = try JSONSerialization.data(withJSONObject: body)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.badServerResponse)
        }
        return content
    }
}
