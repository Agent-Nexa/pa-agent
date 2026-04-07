import SwiftUI
import Combine
#if canImport(Charts)
import Charts
#endif

struct HelpUseCase: Identifiable {
    let id = UUID()
    let title: String
    let iconName: String
    let userLine: String
    let agentLine: String
    let showsDiagramSample: Bool

    init(title: String, iconName: String = "lightbulb", userLine: String, agentLine: String, showsDiagramSample: Bool = false) {
        self.title = title
        self.iconName = iconName
        self.userLine = userLine
        self.agentLine = agentLine
        self.showsDiagramSample = showsDiagramSample
    }
}

private struct HelpDiagramRow: Identifiable {
    let id = UUID()
    let status: String
    let category: String
    let count: Int
}

struct HelpView: View {
    private let useCases: [HelpUseCase] = [
        HelpUseCase(
            title: "Create a Task",
            iconName: "checklist",
            userLine: "user: Remind me to send the project update tomorrow at 9 AM.",
            agentLine: "agent: Got it — I created a task for tomorrow at 9:00 AM and set a reminder."
        ),
        HelpUseCase(
            title: "Send a Message",
            iconName: "message.fill",
            userLine: "user: Text Alex that I will join the meeting 10 minutes late.",
            agentLine: "agent: I prepared a message to Alex: ‘I’ll join the meeting 10 minutes late.’ Ready to send."
        ),
        HelpUseCase(
            title: "Make a Call",
            iconName: "phone.fill",
            userLine: "user: Call Mom after work.",
            agentLine: "agent: I scheduled a call task for after work and can start the call when you’re ready."
        ),
        HelpUseCase(
            title: "Plan with Priority",
            iconName: "flag.fill",
            userLine: "user: Add urgent task to finish tax documents by Friday.",
            agentLine: "agent: Task added with high priority and due Friday. I’ll keep it highlighted until completed."
        ),
        HelpUseCase(
            title: "Quick Daily Check",
            iconName: "calendar",
            userLine: "user: What should I focus on today?",
            agentLine: "agent: You have 3 open tasks today. Start with ‘Prepare client summary’ (high priority)."
        ),
        HelpUseCase(
            title: "Task Status Diagram",
            iconName: "chart.bar.xaxis",
            userLine: "user: Show my task status diagram for today.",
            agentLine: "agent: Here’s a chart of Completed / Overdue / Upcoming tasks, with Work vs Personal breakdown in each status.",
            showsDiagramSample: true
        ),
        HelpUseCase(
            title: "Work vs Personal Progress",
            iconName: "person.2.fill",
            userLine: "user: Summarize my work and personal task progress with a chart.",
            agentLine: "agent: I generated a status chart and highlighted how many Work and Personal tasks are completed, overdue, and upcoming."
        ),
        HelpUseCase(
            title: "Track Custom Data",
            iconName: "chart.line.uptrend.xyaxis",
            userLine: "user: Track $15 for lunch and 30 minutes of running.",
            agentLine: "agent: I logged $15 under 'Spending' and 30 under 'Fitness'. You can view your history in the tracking dashboard."
        ),
        HelpUseCase(
            title: "Share from WhatsApp / iMessage",
            iconName: "square.and.arrow.up.fill",
            userLine: "user: [Shared a WhatsApp message] 'Team lunch this Friday at 1pm at Nobu'",
            agentLine: "agent: Looks like a lunch event on Friday at 1pm. Would you like me to add it to your calendar?"
        ),
        HelpUseCase(
            title: "Share a Receipt Photo",
            iconName: "photo.on.rectangle.angled",
            userLine: "user: [Shared an image] Receipt photo from WhatsApp",
            agentLine: "agent: I can see a receipt for $42.50 at Grab. Would you like me to log this as an expense?"
        )
    ]

    var body: some View {
        VStack(spacing: 10) {
            Text("Swipe to see examples")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TabView {
                ForEach(useCases) { useCase in
                    HelpCarouselCard(useCase: useCase)
                        .padding(.horizontal)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 420)

            Text("Use natural language. Try “Remind me…”, “Text…”, “Call…”, or “Show my task status diagram”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            ShareWithNexaGuideView()
                .padding(.horizontal)
                .padding(.bottom, 8)        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpCarouselCard: View {
    let useCase: HelpUseCase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: useCase.iconName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(useCase.title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(useCase.userLine)
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(useCase.agentLine)
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if useCase.showsDiagramSample {
                    HelpDiagramSampleView()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HelpDiagramSampleView: View {
    private let rows: [HelpDiagramRow] = [
        .init(status: "Completed", category: "Work", count: 4),
        .init(status: "Completed", category: "Personal", count: 2),
        .init(status: "Completed", category: "Other", count: 1),
        .init(status: "Overdue", category: "Work", count: 1),
        .init(status: "Overdue", category: "Personal", count: 2),
        .init(status: "Overdue", category: "Other", count: 1),
        .init(status: "Upcoming", category: "Work", count: 3),
        .init(status: "Upcoming", category: "Personal", count: 2),
        .init(status: "Upcoming", category: "Other", count: 1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample Diagram")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            #if canImport(Charts)
            Chart(rows) { row in
                BarMark(
                    x: .value("Status", row.status),
                    y: .value("Count", row.count)
                )
                .foregroundStyle(by: .value("Category", row.category))
            }
            .chartForegroundStyleScale([
                "Work": .purple,
                "Personal": .mint,
                "Other": .gray
            ])
            .frame(height: 150)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            #else
            VStack(alignment: .leading, spacing: 6) {
                Text("Completed: W4 / P2 / O1")
                Text("Overdue: W1 / P2 / O1")
                Text("Upcoming: W3 / P2 / O1")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        ScrollView {
            HelpView()
        }
    }
}

// MARK: - Share with Nexa Guide

private struct ShareStep: Identifiable {
    let id = UUID()
    let number: Int
    let icon: String
    let title: String
    let detail: String
}

private struct ShareWithNexaGuideView: View {
    @State private var expanded = false

    private let steps: [ShareStep] = [
        ShareStep(number: 1, icon: "hand.tap.fill",        title: "Open any app",          detail: "Go to WhatsApp, iMessage, Safari, or any app that has a message, image, or link you want to share."),
        ShareStep(number: 2, icon: "square.and.arrow.up",  title: "Tap the Share button",  detail: "Long-press a message or image, or tap the Share icon (□↑). This opens the iOS share sheet."),
        ShareStep(number: 3, icon: "ellipsis",             title: "Find Nexa",             detail: "In the top app row tap the Nexa icon. If you don't see it, tap More (•••) and toggle Nexa on. For actions (Copy, Save…) swipe to the second strip and tap Send to Nexa."),
        ShareStep(number: 4, icon: "paperplane.fill",      title: "Tap Send to Nexa",      detail: "A preview sheet appears. Optionally add a note, then tap Send to Nexa."),
        ShareStep(number: 5, icon: "sparkles",             title: "Nexa organises it",     detail: "Switch back to Nexa. The shared content appears in chat and Nexa will suggest the right action — add to calendar, track an expense, set a reminder, and more.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("How to share with Nexa", systemImage: "square.and.arrow.up.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            // Step number circle
                            ZStack {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 30, height: 30)
                                Text("\(step.number)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.purple)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Label(step.title, systemImage: step.icon)
                                    .font(.subheadline.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        if step.number < steps.count {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Daily Tips Feature

struct DailyTip {
    let text: String
    let icon: String // SF Symbol 
}

class DailyTipManager: ObservableObject {
    static let shared = DailyTipManager()
    
    let defaultTips: [DailyTip] = [
        DailyTip(text: "Tip: You can create tracking categories in Tracking menu and ask the agent to track your spending. E.g. \"I spent $17 on lunch today\".", icon: "chart.pie.fill"),
        DailyTip(text: "Tip: Simply scan an invoice or receipt, and the agent will record the expenses for you automatically.", icon: "doc.viewfinder"),
        DailyTip(text: "Did you know? You can ask the agent to remind you about important tasks just by using your voice.", icon: "mic.fill"),
        DailyTip(text: "Save important notes by asking the agent to remember them. Access them later from the Saved Items.", icon: "bookmark.fill"),
        DailyTip(text: "Send quick emails or text messages by telling the agent who to contact and what to say.", icon: "paperplane.fill"),
        DailyTip(text: "Make it personal! Go to Settings to give the agent a custom name, and tell it your name so it greets you personally.", icon: "person.text.rectangle.fill"),
        DailyTip(text: "Tip: Share any message, image, or link from WhatsApp, iMessage, or Safari directly into Nexa — tap the share button and choose Send to Nexa. Nexa will read it and help you organise it.", icon: "square.and.arrow.up.fill"),
        DailyTip(text: "Did you know? Share a WhatsApp message about an upcoming event and Nexa will ask if you'd like to add it to your calendar automatically.", icon: "calendar.badge.plus"),
        DailyTip(text: "Tip: Forward a receipt or invoice photo from any chat app to Nexa and it will extract the amount and offer to track it as an expense for you.", icon: "photo.on.rectangle.angled"),
        DailyTip(text: "Stay organised effortlessly — share your messages and conversations with Nexa and let it decide what to do: schedule events, track expenses, set reminders, and more.", icon: "sparkles")
    ]
    
    @Published var currentTip: DailyTip?
    
    @AppStorage("lastTipDate") private var lastTipDateStr: String = ""
    @AppStorage("lastTipIndex") private var lastTipIndex: Int = -1
    
    // For AI generation
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = ""
    @AppStorage("AGENT_NAME") private var agentName: String = "Nexa"
    @AppStorage("USER_NAME") private var userName: String = ""
    
    init() {
        updateTipIfNeeded()
    }
    
    func updateTipIfNeeded() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        if lastTipDateStr != today {
            lastTipDateStr = today
            lastTipIndex = (lastTipIndex + 1) % defaultTips.count
            
            // Generate a fresh tip in the background if AI is configured
            Task {
                await generateAITip()
            }
        }
        
        if lastTipIndex < 0 || lastTipIndex >= defaultTips.count {
            lastTipIndex = 0
        }
        
        currentTip = defaultTips[lastTipIndex]
    }
    
    @MainActor
    private func generateAITip() async {
        let rawKey = storedApiKey
        guard !rawKey.isEmpty || useAzure else { return }
        
        let chosenModel = storedModel.isEmpty ? "gpt-4o" : storedModel
        
        let endpointURL: URL
        if useAzure {
            guard var azureString = azureEndpoint.isEmpty == false ? azureEndpoint : nil else { return }
            azureString = azureString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            guard let scriptUrl = URL(string: azureString) else { return }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if useAzure {
            if !storedApiKey.isEmpty {
                request.setValue(storedApiKey, forHTTPHeaderField: "api-key")
            }
        } else {
            request.setValue("Bearer \(storedApiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let greeting = userName.isEmpty ? "the user" : userName
        
        let systemPrompt = """
        You are \(agentName), a helpful AI assistant talking to \(greeting). Generate a short, scenario-based daily tip (1-2 sentences) about how \(greeting) can use your features. 
        
        Your ONLY features include: 
        - Managing tasks & reminders
        - Tracking daily habits, weight, calories, or spending (e.g. users can say "I spent $17 on lunch today" or "I ate 500 calories", "Track my weight 70kg")
        - Scanning receipts or invoices to automatically record expenses
        - Remembering facts or notes for the user
        - Sending text messages or emails to contacts
        - Profile customization (users can change the agent's name in Settings and set their own name so the agent addresses them personally)
        
        CRITICAL RULES:
        - Do NOT hallucinate features. You cannot set automatic threshold triggers (like warning about budget limits) or do complex automated integrations not listed above. Only describe actions the user can explicitly ask you to do right now, one-by-one.
        - Be creative, engaging, and scenario-based. For example: "Are you trying to manage your weight? \(agentName) can help you track your calorie intake just by telling me!" or "\(agentName) can help you control your spending. Just scan a receipt and I'll log it for you."
        - Do not use quotes around the tip. Return the tip as a plain string.
        """
        
        let bodyPayload: [String: Any] = [
            "model": chosenModel,
            "temperature": 0.8,
            "messages": [
                ["role": "system", "content": systemPrompt]
            ]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyPayload)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                
                let cleanedTip = content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                
                if !cleanedTip.isEmpty {
                    // Update the UI with the fresh AI tip and pick a suitable icon
                    let iconNames = ["sparkles", "lightbulb.fill", "star.fill", "bolt.fill", "wand.and.stars"]
                    let randomIcon = iconNames.randomElement() ?? "sparkles"
                    
                    self.currentTip = DailyTip(text: cleanedTip, icon: randomIcon)
                }
            }
        } catch {
            print("Failed to generate AI tip: \\(error)")
        }
    }
}

struct DailyTipBanner: View {
    @StateObject private var tipManager = DailyTipManager.shared
    @State private var isVisible = true
    
    var body: some View {
        if isVisible, let tip = tipManager.currentTip {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tip.icon)
                    .foregroundColor(.yellow)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily Tip")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    Text(tip.text)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        isVisible = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(4)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
