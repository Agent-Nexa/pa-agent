//
//  ContentView.swift
//  pa-agent
//
//  Created by ZHEN YUAN on 12/2/2026.
//

import SwiftUI
import Combine
import Speech
import UserNotifications
import AVFoundation
import EventKit
import NaturalLanguage
import Contacts
import MessageUI

// MARK: - Intent models & heuristics

struct IntentResult: Codable {
    var title: String?
    var startDate: Date?
    var dueDate: Date?
    var priority: Int?
    var tag: String?
    
    // Action fields
    var action: String? = "task" // "task" or "sendMessage"
    var recipient: String?
    var messageBody: String?
}

struct IntentAnalyzer {
    private let calendar = Calendar.current

    func infer(from raw: String) -> IntentResult? {
        // Fallback always assumes task
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let priority = parsePriority(lower)
        let tag = parseTag(lower)
        let dates = parseDates(lower)
        let cleanedTitle = cleanTitle(text)

        return IntentResult(
            title: cleanedTitle.isEmpty ? "New task" : cleanedTitle,
            startDate: dates.start,
            dueDate: dates.due,
            priority: priority,
            tag: tag,
            action: "task"
        )
    }

    private func cleanTitle(_ text: String) -> String {
        let stopWords = ["add", "please", "need to", "can you", "todo", "task", "create", "make"]
        var result = text
        for word in stopWords {
            result = result.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "New task" }
        return result.prefix(1).capitalized + result.dropFirst()
    }

    private func parsePriority(_ lower: String) -> Int {
        if lower.contains("urgent") || lower.contains("high") || lower.contains("asap") {
            return 1
        }
        if lower.contains("low") || lower.contains("later") {
            return 3
        }
        return 2
    }

    private func parseTag(_ lower: String) -> String {
        if lower.contains("work") || lower.contains("office") { return "Work" }
        if lower.contains("home") || lower.contains("personal") { return "Personal" }
        if lower.contains("school") || lower.contains("class") { return "School" }
        return "Inbox"
    }

    private func parseDates(_ lower: String) -> (start: Date, due: Date) {
        let now = Date()
        var start = calendar.startOfDay(for: now).addingTimeInterval(9 * 3600) // default 9am today
        var due = calendar.startOfDay(for: now.addingTimeInterval(86_400)).addingTimeInterval(17 * 3600) // default 5pm tomorrow

        func next(_ weekday: Int) -> Date? {
            calendar.nextDate(after: now, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTimePreservingSmallerComponents)
        }

        if lower.contains("tomorrow") {
            if let s = calendar.date(byAdding: .day, value: 1, to: start) { start = s }
            due = start.addingTimeInterval(8 * 3600)
        } else if lower.contains("today") || lower.contains("tonight") {
            due = start.addingTimeInterval(8 * 3600)
        } else if lower.contains("next week") {
            if let s = calendar.date(byAdding: .day, value: 7, to: start) { start = s }
            due = start.addingTimeInterval(8 * 3600)
        } else {
            let weekdays: [(String, Int)] = [
                ("monday", 2), ("tuesday", 3), ("wednesday", 4),
                ("thursday", 5), ("friday", 6), ("saturday", 7), ("sunday", 1)
            ]
            if let match = weekdays.first(where: { lower.contains($0.0) }), let date = next(match.1) {
                start = calendar.startOfDay(for: date).addingTimeInterval(9 * 3600)
                due = start.addingTimeInterval(8 * 3600)
            }
        }
        return (start, due)
    }
}

// MARK: - Models

struct TaskItem: Identifiable, Hashable, Codable {
    enum SourceType: String, Codable {
        case app
        case calendar
        case reminder
    }
    
    var id = UUID()
    var title: String
    var isDone: Bool = false
    var tag: String = "General"
    var startDate: Date = .now
    var dueDate: Date = .now.addingTimeInterval(60 * 60 * 24)
    var priority: Int = 2
    var type: SourceType = .app
    var externalId: String? = nil

    var priorityLabel: String {
        switch priority {
        case 1: return "High"
        case 2: return "Medium"
        default: return "Low"
        }
    }
}

final class IntentService {
    private let fallback = IntentAnalyzer()
    private(set) var usedOpenAI: Bool = false
    private(set) var lastReason: String = "not-run"
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let session = URLSession(configuration: .default)

    func infer(from text: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?) async -> IntentResult? {
        guard let rawKey = apiKey, !rawKey.isEmpty else {
            usedOpenAI = false
            lastReason = "missing API key"
            return fallback.infer(from: text)
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let endpointURL: URL
        // Azure deployments usually ignore 'model' in body, but we pass it anyway or default to gpt-4o for standard OpenAI
        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        
        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                usedOpenAI = false
                lastReason = "invalid Azure URL"
                return fallback.infer(from: text)
            }
            
            // If the URL contains "deployments/...", we try to replace the deployment name with the chosen model
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            
            guard let scriptUrl = URL(string: azureString) else {
                usedOpenAI = false
                lastReason = "invalid Azure URL"
                return fallback.infer(from: text)
            }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if useAzure {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
            // Azure 2024-12-01-preview + gpt-5.2/o1 models do NOT support max_tokens.
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let nowString = df.string(from: Date())

        let body: [String: Any] = [
            "model": chosenModel,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "You are a personal assistant. Determine the user's intent: 'task' or 'sendMessage'. \n1. If Task: Return JSON with action='task', title, startDate, dueDate, priority, tag. Use current time \(nowString). \n2. If Send Message: Return JSON with action='sendMessage', recipient (extract name or number), messageBody (content). \nReply ONLY valid JSON."],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                usedOpenAI = false
                lastReason = "no http response"
                return fallback.infer(from: text)
            }
            guard 200..<300 ~= http.statusCode else {
                usedOpenAI = false
                lastReason = "HTTP \(http.statusCode)"
                return fallback.infer(from: text)
            }

            if let result = parseOpenAIResponse(data: data) {
                usedOpenAI = true
                lastReason = "ok"
                return result
            } else {
                usedOpenAI = false
                lastReason = "parse failure"
                return fallback.infer(from: text)
            }
        } catch {
            usedOpenAI = false
            lastReason = "network/error"
            return fallback.infer(from: text)
        }
    }

    func testConnection(apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?) async -> String {
        guard let rawKey = apiKey, !rawKey.isEmpty else { return "missing API key" }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        
        let endpointURL: URL
        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                 return "Invalid Azure URL"
            }
            
            // If the URL contains "deployments/...", we try to replace the deployment name with the chosen model
            // Pattern: .../deployments/{deployment-name}/...
            // We'll use a simple regex or string replacement if it matches the standard pattern
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            
            guard let scriptUrl = URL(string: azureString) else {
                return "Invalid Azure URL"
            }
            endpointURL = scriptUrl
        } else {
             endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }
        
        print("Test Connection: \(endpointURL.absoluteString)")
        print("Using Key: \(apiKey.prefix(6))...\(apiKey.suffix(4))")

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if useAzure {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
            // Azure 2024-12-01-preview + gpt-5.2/o1 models do NOT support max_tokens.
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            // Azure: model value in body is often ignored or must match deployment. 
            // We'll keep sending it, but it's redundant.
            "model": chosenModel, 
            "messages": [
                ["role": "user", "content": "Return JSON {\"ok\":true}"]
            ],
            "response_format": ["type": "json_object"],
            // Note: temperature 0 is fine
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "no http response" }
            
            if !(200..<300 ~= http.statusCode) {
                if let errText = String(data: data, encoding: .utf8) {
                    print("Connection failed body: \(errText)")
                }
                if http.statusCode == 429 {
                    return "Error 429 (Check Billing)"
                }
                return "HTTP \(http.statusCode)" 
            }
            let text = String(data: data, encoding: .utf8) ?? "no body"
            print("Response body: \(text)") 
            
            // 1. Try string match (relaxed)
            if text.contains("ok") && text.contains("true") { return "ok" }
            
            // 2. Try proper JSON parsing (more robust)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                   if content.contains("ok") && content.contains("true") { return "ok" }
            }
            
            return "parse fail"
        } catch {
            print("Network error: \(error)")
            return "network/error"
        }
    }
    private func parseOpenAIResponse(data: Data) -> IntentResult? {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        struct Root: Decodable { let choices: [Choice] }

        guard let root = try? JSONDecoder().decode(Root.self, from: data),
              let contentRaw = root.choices.first?.message.content
        else { return nil }

        let content = stripCodeFences(contentRaw)
        guard let jsonData = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }

        let title = (dict["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let priority = dict["priority"] as? Int ?? 2
        let tag = (dict["tag"] as? String ?? "Inbox").capitalized
        
        // Check action
        let action = dict["action"] as? String ?? "task"
        let recipient = dict["recipient"] as? String
        let messageBody = dict["messageBody"] as? String

        func parseDate(_ value: Any?) -> Date? {
            guard let s = value as? String else { return nil }
            if let iso = ISO8601DateFormatter().date(from: s) { return iso }
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .gregorian)
            df.timeZone = .current
            df.locale = .current
            df.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let d = df.date(from: s) { return d }
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let d = df.date(from: s) { return d }
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: s) { return d }
            return nil
        }

        let start = parseDate(dict["startDate"]) ?? Calendar.current.startOfDay(for: Date()).addingTimeInterval(9*3600)
        let due = parseDate(dict["dueDate"]) ?? Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)).addingTimeInterval(17*3600)
        
        if action == "sendMessage" {
            return IntentResult(
                action: "sendMessage",
                recipient: recipient,
                messageBody: messageBody
            )
        }

        return IntentResult(
            title: title ?? "New Task",
            startDate: start,
            dueDate: due,
            priority: min(max(priority, 1), 3),
            tag: tag,
            action: "task"
        )
    }

    private func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let start = t.range(of: "```") {
                t.removeSubrange(start)
            }
            if let end = t.range(of: "```", options: .backwards) {
                t.removeSubrange(end)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let timestamp: Date = .init()
}

struct TaskDraft {
    var title: String
    var startDate: Date = .now
    var dueDate: Date = .now.addingTimeInterval(60 * 60 * 24)
    var priority: Int = 2
    var tag: String = "Inbox"
}

struct MessageDraft {
    var recipient: String = ""
    var body: String = ""
}

enum InteractionState: Equatable {
    case idle
    case collectingMessageRecipient
    case collectingMessageBody
    case clarifyingContact(candidates: [SimpleContact])
}

struct SimpleContact: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var number: String
    var label: String
}

class ContactHelpers {
    private let store = CNContactStore()
    
    func requestAccess() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }
    
    func find(name: String) async -> [SimpleContact] {
        guard await requestAccess() else { return [] }
        
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            var results: [SimpleContact] = []
            
            for c in contacts {
                let fullName = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
                for num in c.phoneNumbers {
                    results.append(SimpleContact(
                        name: fullName,
                        number: num.value.stringValue,
                        label: CNLabeledValue<NSString>.localizedString(forLabel: num.label ?? "Mobile")
                    ))
                }
            }
            return results
        } catch {
            return []
        }
    }
}

// MARK: - Speech recognizer

@MainActor
final class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var transcript: String = ""
    @Published var isRecording = false
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                self.authorizationStatus = status
            }
        }
    }

    func startRecording() {
        guard authorizationStatus == .authorized else {
            requestPermission()
            return
        }
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.request?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true

        task = recognizer?.recognitionTask(with: request ?? SFSpeechAudioBufferRecognitionRequest()) { result, error in
            if let result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopRecording()
            }
        }
    }

    func stopRecording() {
        audioEngine.stop()
        request?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
    }
}

// MARK: - View

struct ContentView: View {
    @State private var tasks: [TaskItem] = []
    @State private var messages: [ChatMessage] = [
        .init(isUser: false, text: "Hi! I’m your project agent. Tell me what you need and I’ll track and prioritize tasks for you.")
    ]
    @State private var draft: String = ""
    @State private var pendingDraft: TaskDraft = .init(title: "")
    @State private var pendingMessage: MessageDraft = .init()
    @State private var interactionState: InteractionState = .idle
    @State private var showTaskDetailSheet = false
    @State private var showNotificationAlert = false
    @State private var showCalendarAlert = false
    @State private var lastIntentSource: String = "fallback"
    @State private var lastIntentReason: String = "not-run"
    @State private var showKeySheet = false
    @State private var showSettingsSheet = false
    @State private var showTasksList = false
    @State private var showMessageComposer = false
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://admin-mev0a1yu-eastus2.openai.azure.com/openai/deployments/gpt-5.2/chat/completions?api-version=2024-12-01-preview"
    @StateObject private var speechManager = SpeechManager()
    @Namespace private var scrollSpace
    private let eventStore = EKEventStore()
    private let intentAnalyzer = IntentAnalyzer()
    private let intentService = IntentService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                chatArea
                Divider()
                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .sheet(isPresented: $showTaskDetailSheet) {
                taskDetailSheet
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView()
            }
            .sheet(isPresented: $showTasksList) {
                TasksListSheet(tasks: $tasks)
            }
            .sheet(isPresented: $showMessageComposer) {
                MessageComposerView(recipients: [pendingMessage.recipient], body: pendingMessage.body) { result in
                    if result == .sent {
                        // Mark as done immediately
                        recordSentMessageAsTask(recipient: pendingMessage.recipient, body: pendingMessage.body)
                        messages.append(.init(isUser: false, text: "Message sent and logged."))
                    } else if result == .cancelled {
                        messages.append(.init(isUser: false, text: "Message cancelled."))
                    } else {
                        messages.append(.init(isUser: false, text: "Message failed."))
                    }
                    pendingMessage = .init()
                }
            }
            .alert("Reminder not scheduled", isPresented: $showNotificationAlert, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text("I couldn't schedule a start-date reminder. Check notification permissions.")
            })
            .alert("Calendar access needed", isPresented: $showCalendarAlert, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text("I couldn't add the task to Calendar. Please enable calendar access in Settings.")
            })
            .onAppear {
                loadTasks()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
                speechManager.requestPermission()
                Task { 
                    await requestCalendarAccessIfNeeded()
                    await requestRemindersAccessIfNeeded()
                }
            }
            .onChange(of: tasks) { _, _ in saveTasks() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Chat")
                    .font(.title.bold())
                Text("Speak tasks, capture details, and keep priorities tight.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Intent: \(lastIntentSource) (\(lastIntentReason))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Settings") { showSettingsSheet = true }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            Spacer()
            Menu {
                Button("Tasks", action: { showTasksList = true })
                Button("Quick reset", action: resetChat)
                Button("Clear tasks", action: clearTasks)
                Button("Settings") { showSettingsSheet = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: Chat

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        messageBubble(for: message)
                            .id(message.id)
                    }

                    if case .clarifyingContact(let candidates) = interactionState {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select a contact:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(candidates) { contact in
                                Button {
                                    Task { await confirmContact(contact) }
                                } label: {
                                    HStack {
                                        Text(contact.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(contact.label).font(.caption).foregroundStyle(.secondary)
                                        Text(contact.number).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding()
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .onChange(of: messages) { _, newValue in
                    if let last = newValue.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: interactionState) { _, newState in
                    if case .clarifyingContact = newState {
                        // Scroll to bottom when options appear
                        if let last = messages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private func messageBubble(for message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.isUser ? "You" : "Agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .padding()
                    .background(message.isUser ? Color.accentColor.opacity(0.15) : Color.white)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.05))
                    )
            }
            if !message.isUser { Spacer() }
        }
        .transition(.move(edge: message.isUser ? .trailing : .leading).combined(with: .opacity))
    }

    // MARK: Task board

    private var taskBoard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                Spacer()
                Button {
                    pendingDraft = TaskDraft(title: "New task")
                    showTaskDetailSheet = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tasks) { task in
                        taskCard(task)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func taskCard(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.tag.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    toggleTask(task)
                } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isDone ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            Text(task.title)
                .font(.subheadline)
                .foregroundStyle(task.isDone ? .secondary : .primary)
            HStack(spacing: 6) {
                Label(task.priorityLabel, systemImage: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(priorityColor(task.priority))
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(task.dueDate, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text("Start: \(task.startDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background)
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
    }

    // MARK: Task List Sheet
    
    struct TasksListSheet: View {
        @Binding var tasks: [TaskItem]
        @Environment(\.dismiss) private var dismiss
        @State private var selectedFilter: TaskFilter = .all

        enum TaskFilter: String, CaseIterable {
            case all = "All"
            case today = "Today"
        case upcoming = "Upcoming"
    }

    var filteredTasks: [TaskItem] {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: todayStart)!

        return tasks.filter { task in
            let targetDate = task.dueDate
            switch selectedFilter {
            case .all:
                return true
            case .today:
                return targetDate < tomorrowStart 
            case .upcoming:
                return targetDate >= tomorrowStart && targetDate < nextWeekStart
            }
        }
        .sorted { 
             // Sort by date, then priority
             if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
             return $0.priority < $1.priority 
        }
    }

    var body: some View {
            NavigationStack {
                List {
                    ForEach(filteredTasks) { task in
                        HStack {
                            Button {
                                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                                    withAnimation { tasks[index].isDone.toggle() }
                                }
                            } label: {
                                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(task.isDone ? .green : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading) {
                                Text(task.title)
                                    .font(.headline)
                                    .strikethrough(task.isDone)
                                    .foregroundStyle(task.isDone ? .secondary : .primary)
                                Text("\(task.type == .calendar ? "📅 " : "")Due: \(task.dueDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(task.priorityLabel)
                                .font(.caption2)
                                .padding(4)
                                .background(priorityColor(task.priority).opacity(0.2))
                                .foregroundStyle(priorityColor(task.priority))
                                .cornerRadius(4)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                                    tasks.remove(at: index)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(task.isDone ? "Undo" : "Done") {
                                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                                    withAnimation { tasks[index].isDone.toggle() }
                                }
                            }
                            .tint(.green)
                        }
                        .listRowBackground(
                            (task.dueDate < Date() && !task.isDone) ? Color.red.opacity(0.15) : nil
                        )
                    }
                }
                .navigationTitle("Tasks")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Filter", selection: $selectedFilter) {
                            ForEach(TaskFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack {
                        Text("Total Tasks: \(tasks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reset All Tasks") {
                            tasks.removeAll()
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                    .padding()
                    .background(.regularMaterial)
                }
                .overlay {
                    if filteredTasks.isEmpty {
                        ContentUnavailableView(
                            "No tasks for \(selectedFilter.rawValue.lowercased())",
                            systemImage: "checklist",
                            description: Text("Add some tasks by chatting with the agent.")
                        )
                    }
                }
            }
        }
        
        private func priorityColor(_ value: Int) -> Color {
            switch value {
            case 1: return .red
            case 2: return .orange
            default: return .blue
            }
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    speechManager.isRecording ? speechManager.stopRecording() : speechManager.startRecording()
                    draft = speechManager.transcript
                } label: {
                    Image(systemName: speechManager.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(speechManager.isRecording ? .red : .accentColor)
                }

                TextField("Say or type what you need…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .background(.thinMaterial)
        .onChange(of: speechManager.transcript) { _, newValue in
            if speechManager.isRecording {
                draft = newValue
            }
        }
    }

    // MARK: Task detail sheet

    private var taskDetailSheet: some View {
        NavigationStack {
            Form {
                Section("Title & Tag") {
                    TextField("Task title", text: $pendingDraft.title)
                    TextField("Tag", text: $pendingDraft.tag)
                }
                Section("Schedule") {
                    DatePicker("Start", selection: $pendingDraft.startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Due", selection: $pendingDraft.dueDate, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Priority") {
                    Picker("Priority", selection: $pendingDraft.priority) {
                        Text("High").tag(1)
                        Text("Medium").tag(2)
                        Text("Low").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Confirm task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showTaskDetailSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { commitPendingTask() }
                        .disabled(pendingDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Messaging logic

    private func sendMessage() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(isUser: true, text: trimmed)
        messages.append(userMessage)
        draft = ""

        Task { await handleIntent(for: trimmed) }
    }
    
    private func confirmContact(_ contact: SimpleContact) async {
        pendingMessage.recipient = contact.number
        messages.append(.init(isUser: true, text: "Selected: \(contact.name) (\(contact.label))"))
        await checkMessageCompleteness()
    }
    
    private func resolveAndProceed(recipient: String) async {
        let digits = recipient.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        // If it looks like a number (at least 7 digits), just use it
        if digits.count >= 7 {
            pendingMessage.recipient = recipient
            await checkMessageCompleteness()
            return
        }
        
        let candidates = await ContactHelpers().find(name: recipient)
        if candidates.isEmpty { 
            // Fallback: use raw input
            pendingMessage.recipient = recipient
            await checkMessageCompleteness()
        } else if candidates.count == 1 {
            let c = candidates.first!
            withAnimation {
                messages.append(.init(isUser: false, text: "Found \(c.name)."))
            }
            pendingMessage.recipient = c.number
            await checkMessageCompleteness()
        } else {
            interactionState = .clarifyingContact(candidates: candidates)
            withAnimation {
                messages.append(.init(isUser: false, text: "I found multiple contacts for '\(recipient)'. Please pick one:"))
            }
        }
    }
    
    private func checkMessageCompleteness() async {
        if pendingMessage.recipient.isEmpty {
            interactionState = .collectingMessageRecipient
            withAnimation { messages.append(.init(isUser: false, text: "Who would you like to message?")) }
            return
        }
        if pendingMessage.body.isEmpty {
            interactionState = .collectingMessageBody
            withAnimation { messages.append(.init(isUser: false, text: "What's the message?")) }
            return
        }
        await finalizeMessage()
    }

    private func handleIntent(for text: String) async {
        // 0. Check disambiguation
        if case .clarifyingContact(let candidates) = interactionState {
            if let match = candidates.first(where: { $0.name.localizedCaseInsensitiveContains(text) }) {
                await confirmContact(match)
            } else {
                pendingMessage.recipient = text
                await checkMessageCompleteness()
            }
            return
        }
    
        // 1. Check if we are filling a slot
        if interactionState == .collectingMessageRecipient {
            await resolveAndProceed(recipient: text)
            return
        }
        
        if interactionState == .collectingMessageBody {
            pendingMessage.body = text
            await checkMessageCompleteness()
            return
        }
    
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey

        if let draft = await intentService.infer(from: text, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint) ?? intentAnalyzer.infer(from: text) {
            lastIntentSource = intentService.usedOpenAI ? "openai" : "fallback"
            lastIntentReason = intentService.lastReason
            
            if draft.action == "sendMessage" {
                pendingMessage = MessageDraft(recipient: "", body: draft.messageBody ?? "")
                
                if let raw = draft.recipient, !raw.isEmpty {
                    await resolveAndProceed(recipient: raw)
                } else {
                    await checkMessageCompleteness()
                }
                return
            }
            
            // Task Logic
            pendingDraft = TaskDraft(
                title: draft.title ?? "New Task",
                startDate: draft.startDate ?? Date(),
                dueDate: draft.dueDate ?? Date().addingTimeInterval(86400),
                priority: draft.priority ?? 2,
                tag: draft.tag ?? "Inbox"
            )
            showTaskDetailSheet = true
        } else {
            lastIntentSource = intentService.usedOpenAI ? "openai" : "fallback"
            lastIntentReason = intentService.lastReason
            promptForTaskDetails(from: text)
        }
    }

    private func finalizeMessage() async {
        interactionState = .idle
        await MainActor.run {
            if MFMessageComposeViewController.canSendText() {
                showMessageComposer = true
            } else {
                #if targetEnvironment(simulator)
                // Simulate success for testing on Simulator
                messages.append(.init(isUser: false, text: "Simulating SMS send (Simulator mode)..."))
                recordSentMessageAsTask(recipient: pendingMessage.recipient, body: pendingMessage.body)
                messages.append(.init(isUser: false, text: "Message sent and logged."))
                pendingMessage = .init()
                #else
                messages.append(.init(isUser: false, text: "This device cannot send messages. Make sure you are on a phone with a SIM card."))
                pendingMessage = .init()
                #endif
            }
        }
    }
    
    private func recordSentMessageAsTask(recipient: String, body: String) {
        // Add a "completed" task for the message
        let task = TaskItem(
            title: "Sent message to \(recipient)",
            isDone: true,
            tag: "Personal",
            startDate: Date(),
            dueDate: Date(),
            priority: 3 // Low priority for log/history
        )
        // We insert it directly. "insertTask" does calendar stuff which we might not want for a just-completed log.
        // But the user said "add that as a complete tasks". 
        // Let's just append and sort.
        tasks.append(task)
        reprioritize()
    }

    private func promptForTaskDetails(from text: String) {
        let cleaned = text
            .replacingOccurrences(of: "add", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "task", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "todo", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let title = cleaned.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
        pendingDraft = TaskDraft(title: title)

        // Keep the sheet open so the user can refine details if they want.
        showTaskDetailSheet = true
    }

    private func generateAssistantResponse(for text: String) -> String {
        if text.lowercased().contains("summary") {
            let open = tasks.filter { !$0.isDone }
            let bullet = open.prefix(3).map { "- \($0.title) due \($0.dueDate.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: " ")
            return open.isEmpty ? "No open tasks. Want to add one?" : "Here's the next steps: \(bullet)"
        }
        if text.lowercased().contains("help") {
            return "Try: “Add prep deck for Q4 review due Friday, high priority.”"
        }
        return "Noted. Should I turn that into a task?"
    }

    private func commitPendingTask() {
        let newTask = TaskItem(
            title: pendingDraft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            tag: pendingDraft.tag,
            startDate: pendingDraft.startDate,
            dueDate: pendingDraft.dueDate,
            priority: pendingDraft.priority
        )
        insertTask(newTask, announce: true)

        pendingDraft = TaskDraft(title: "")
        showTaskDetailSheet = false
    }

    private func insertTask(_ newTask: TaskItem, announce: Bool) {
        tasks.append(newTask)
        reprioritize()
        scheduleReminder(for: newTask)
        Task { await addCalendarEvent(for: newTask) }

        guard announce else { return }

        let conflict = tasks
            .filter { $0.id != newTask.id && Calendar.current.isDate($0.dueDate, inSameDayAs: newTask.dueDate) }
            .sorted { $0.priority < $1.priority }

        var confirmation = "Added “\(newTask.title)”. I prioritized it with due date \(newTask.dueDate.formatted(date: .abbreviated, time: .omitted))."
        if let topConflict = conflict.first {
            confirmation += " It shares the same due date with “\(topConflict.title)”; higher priority is first."
        }

        withAnimation(.easeIn(duration: 0.2)) {
            messages.append(.init(isUser: false, text: confirmation))
        }
    }

    // MARK: Calendar

    private func requestCalendarAccessIfNeeded() async {
        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .notDetermined:
                do {
                    let granted = try await eventStore.requestFullAccessToEvents()
                    if !granted { await MainActor.run { showCalendarAlert = true } }
                } catch { await MainActor.run { showCalendarAlert = true } }
            case .denied, .restricted:
                await MainActor.run { showCalendarAlert = true }
            default:
                break
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .notDetermined:
                do {
                    let granted = try await eventStore.requestAccess(to: .event)
                    if !granted { await MainActor.run { showCalendarAlert = true } }
                } catch { await MainActor.run { showCalendarAlert = true } }
            case .denied, .restricted:
                await MainActor.run { showCalendarAlert = true }
            default:
                break
            }
        }
    }

    private func addCalendarEvent(for task: TaskItem) async {
        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess || status == .writeOnly else { return }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .authorized else { return }
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = task.title
        event.calendar = eventStore.defaultCalendarForNewEvents

        // Set event window: start at 9am on start date, 30 minutes duration
        var startComponents = Calendar.current.dateComponents([.year, .month, .day], from: task.startDate)
        startComponents.hour = 9
        let start = Calendar.current.date(from: startComponents) ?? task.startDate
        event.startDate = start
        event.endDate = start.addingTimeInterval(30 * 60)
        event.notes = "Due: \(task.dueDate.formatted(date: .abbreviated, time: .omitted)) • Priority: \(task.priorityLabel)"

        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            await MainActor.run { showCalendarAlert = true }
        }
    }

    private func requestRemindersAccessIfNeeded() async {
        if #available(iOS 17, *) {
           let status = EKEventStore.authorizationStatus(for: .reminder)
           if status == .notDetermined {
               try? await eventStore.requestFullAccessToReminders()
           }
        } else {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            if status == .notDetermined {
                try? await eventStore.requestAccess(to: .reminder)
            }
        }
    }

    private func fetchSystemItems() -> [TaskItem] {
        let calendar = Calendar.current
        var fetchedItems: [TaskItem] = []
        
        // Window: -1 year to +1 year
        let now = Date()
        let start = calendar.date(byAdding: .year, value: -1, to: now)!
        let end = calendar.date(byAdding: .year, value: 1, to: now)!
        
        // Fetch only relevant calendars (exclude Holidays, Birthdays, etc.)
        let allCalendars = eventStore.calendars(for: .event)
        let userCalendars = allCalendars.filter { cal in
            // Exclude subscription (Holidays) and Birthdays
            cal.type != .subscription && cal.type != .birthday
        }

        // 1. Fetch Events
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: userCalendars)
        let events = eventStore.events(matching: predicate)
        for event in events {
            fetchedItems.append(TaskItem(
                id: UUID(), // We generate a transient ID
                title: event.title ?? "Event",
                isDone: false, // Events are not checkable in valid sense, but assume false
                tag: event.calendar.title,
                startDate: event.startDate,
                dueDate: event.endDate,
                priority: 2,
                type: .calendar,
                externalId: event.eventIdentifier
            ))
        }
        
        return fetchedItems
    }

    private func reprioritize() {
        tasks.sort { lhs, rhs in
            if !Calendar.current.isDate(lhs.dueDate, inSameDayAs: rhs.dueDate) {
                return lhs.dueDate < rhs.dueDate
            }
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.startDate < rhs.startDate
        }
    }

    private func scheduleReminder(for task: TaskItem) {
        let content = UNMutableNotificationContent()
        content.title = "Starts today: \(task.title)"
        content.body = "Tag: \(task.tag) • Due \(task.dueDate.formatted(date: .abbreviated, time: .omitted))"
        content.sound = .default

        var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: task.startDate)
        dateComponents.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                Task { @MainActor in showNotificationAlert = true }
            }
        }
    }

    // MARK: Helpers

    private func saveTasks() {
        // Only save items created within the app
        let appTasks = tasks.filter { $0.type == .app }
        if let data = try? JSONEncoder().encode(appTasks) {
            UserDefaults.standard.set(data, forKey: "saved_tasks")
        }
    }

    private func loadTasks() {
        var baseTasks: [TaskItem] = []
        if let data = UserDefaults.standard.data(forKey: "saved_tasks") {
            do {
                baseTasks = try JSONDecoder().decode([TaskItem].self, from: data)
            } catch {
                print("Failed to load tasks: \(error)")
            }
        }
        
        if baseTasks.isEmpty {
           baseTasks = [
               .init(title: "Review roadmap with PM", tag: "Work", startDate: .now, dueDate: .now.addingTimeInterval(86_400.0 * 2), priority: 1)
           ]
        }
        
        // Combine with system items
        // Note: In a real app we would not effectively re-append system items to the 'tasks' array on every load 
        // if 'tasks' is binding back to storage. We should separate them.
        // However, given the current simple structure where 'tasks' is the single source of truth for the list view,
        // we will append them transiently. 
        // CRITICAL: We must filter out previous system items before appending new ones to avoid duplicates if we save this array back.
        
        let existingAppTasks = baseTasks.filter { $0.type == .app }
        let systemItems = fetchSystemItems()
        tasks = existingAppTasks + systemItems
        
        print("Loaded \(existingAppTasks.count) app tasks + \(systemItems.count) system events")
    }

    private func priorityColor(_ value: Int) -> Color {
        switch value {
        case 1: return .red
        case 2: return .orange
        default: return .blue
        }
    }

    private func toggleTask(_ task: TaskItem) {
        guard let index = tasks.firstIndex(of: task) else { return }
        tasks[index].isDone.toggle()
    }

    private func resetChat() {
        withAnimation(.easeInOut) {
            messages = [.init(isUser: false, text: "Hi! I’m your project agent. Tell me what you need and I’ll track and prioritize tasks for you.")]
        }
    }

    private func clearTasks() {
        withAnimation(.easeInOut) {
            tasks.removeAll()
        }
    }
}

struct MessageComposerView: UIViewControllerRepresentable {
    var recipients: [String]
    var body: String
    var completion: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var completion: (MessageComposeResult) -> Void

        init(completion: @escaping (MessageComposeResult) -> Void) {
            self.completion = completion
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true) {
                self.completion(result)
            }
        }
    }
}

#Preview {
    ContentView()
}
