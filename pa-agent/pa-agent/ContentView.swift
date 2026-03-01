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
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Charts)
import Charts
#endif
#if canImport(MessageUI)
import MessageUI
#endif


// MARK: - Intent models & heuristics

struct IntentResult: Codable {
    var title: String? = nil
    var startDate: Date? = nil
    var dueDate: Date? = nil
    var priority: Int? = nil
    var tag: String? = nil
    
    // Action fields
    var action: String? = "task" // "task", "sendMessage", "makePhoneCall", "sendEmail", "greeting", "answer"
    var recipient: String? = nil
    var messageBody: String? = nil
    var subject: String? = nil
    var callScript: String? = nil
    var answer: String? = nil // For greetings and QA

    
    // Delegation fields
    var performer: String? = "user" // "user" or "agent"
    var isScheduled: Bool? = false // inferred from presence of dates vs "now"
    
    // Tracking fields
    var trackingCategoryId: String? = nil
    var trackingValue: Double? = nil
    var trackingNote: String? = nil
}

struct IntentAnalyzer {
    private let calendar = Calendar.current

    func infer(from raw: String, agentName: String = "Nexa") -> IntentResult? {
        // Fallback always assumes task
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let nameLower = agentName.lowercased()
        
        // Simple heuristics for call/message
        if lower.starts(with: "call ") || lower.starts(with: "phone ") || lower.starts(with: "dial ") {
            let recipient = text.replacingOccurrences(of: "call ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "phone ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "dial ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return IntentResult(action: "makePhoneCall", recipient: recipient)
        }
        
        if (lower.starts(with: "message ") || lower.starts(with: "text ") || lower.starts(with: "send a message") || lower.contains("send message")) {
             // Basic extraction is hard without NLP, but we can try
             // "Text Mom I'm late" -> Recipient: Mom, Body: I'm late
             // This is very rough, assumes OpenAI usually handles it.
             return IntentResult(action: "sendMessage", recipient: "", messageBody: "")
        }

        if lower.starts(with: "email ") || lower.starts(with: "send email ") || lower.contains("send an email") {
             return IntentResult(action: "sendEmail", recipient: "", messageBody: "")
        }

        var greetings = ["hi", "hello", "hey", "good morning", "good afternoon", "good evening", "greetings"]
        if !nameLower.isEmpty { greetings.append(nameLower) }
        
        // Strict greeting check: Only return greeting if the remainder is negligible.
        // This prevents "Hi, remind me to..." being trapped as a greeting.
        for greeting in greetings {
             if lower == greeting {
                 return IntentResult(action: "greeting", answer: "Hello! I'm \(agentName). How can I help you today?")
             }
             if lower.hasPrefix(greeting + " ") || lower.hasPrefix(greeting + ",") || lower.hasPrefix(greeting + "!") {
                 // Check if there is substantial content after the greeting
                 let range = lower.range(of: greeting)!
                 let remainder = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                 if remainder.isEmpty {
                      return IntentResult(action: "greeting", answer: "Hello! I'm \(agentName). How can I help you today?")
                 }
             }
        }


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
    
    enum Executor: String, Codable {
        case user
        case agent
    }

    enum TaskStatus: String, Codable {
        case open
        case completed
        case canceled
    }
    
    struct AgentAction: Codable, Hashable {
        var type: String // "call", "sendMessage", "makePhoneCall", "sendEmail"
        var recipient: String
        var body: String? // For messages/emails
        var subject: String? // For emails
        var script: String? // For calls
    }
    
    var id = UUID()
    var title: String
    var isDone: Bool = false
    var status: TaskStatus = .open
    var tag: String = "General"
    var startDate: Date = .now
    var dueDate: Date = .now.addingTimeInterval(60 * 60 * 24)
    var completedAt: Date? = nil
    var priority: Int = 2
    var type: SourceType = .app
    var externalId: String? = nil
    
    // New fields for Agent delegation
    var executor: Executor = .user
    var actionPayload: AgentAction? = nil

    var priorityLabel: String {
        switch priority {
        case 1: return "High"
        case 2: return "Medium"
        default: return "Low"
        }
    }

    var statusLabel: String {
        if isOverdue() {
            return "Overdue"
        }
        switch status {
        case .open: return "Open"
        case .completed: return "Completed"
        case .canceled: return "Canceled"
        }
    }

    var categoryLabel: String {
        let lower = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("work") || lower.contains("office") || lower.contains("client") || lower.contains("project") {
            return "Work"
        }
        if lower.contains("personal") || lower.contains("home") || lower.contains("family") {
            return "Personal"
        }
        return "Uncategorized"
    }

    var categoryIconName: String {
        switch categoryLabel {
        case "Work":
            return "briefcase.fill"
        case "Personal":
            return "person.fill"
        default:
            return "questionmark.circle.fill"
        }
    }

    mutating func markCompleted() {
        isDone = true
        status = .completed
        completedAt = Date()
    }

    mutating func markCanceled() {
        isDone = true
        status = .canceled
        completedAt = nil
    }

    mutating func markOpen() {
        isDone = false
        status = .open
        completedAt = nil
    }

    mutating func toggleDoneState() {
        if isDone {
            markOpen()
        } else {
            markCompleted()
        }
    }

    func isOverdue(now: Date = Date(), ignoringOlderThanMonths months: Int = 1) -> Bool {
        guard status == .open, !isDone, dueDate < now else { return false }
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now) else {
            return dueDate < now
        }
        return dueDate >= cutoff
    }

    func isStaleOverdue(now: Date = Date(), months: Int = 1) -> Bool {
        guard status == .open, !isDone else { return false }
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now) else {
            return false
        }
        return dueDate < cutoff
    }
}

struct CalendarEventStartDateStore {
    static let key = "CALENDAR_EVENTS_START_DATE"

    static var defaultDate: Date {
        Calendar.current.startOfDay(for: Date())
    }

    static var defaultTimestamp: Double {
        defaultDate.timeIntervalSince1970
    }

    static func normalizedDate(from timestamp: Double) -> Date {
        guard timestamp.isFinite else {
            return defaultDate
        }

        let clampedTimestamp = min(max(timestamp, 0), 4_102_444_800)
        return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: clampedTimestamp))
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
    private let tokenUsageManager = TokenUsageManager.shared

    func infer(from text: String, imageDataURL: String? = nil, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, userName: String?, agentName: String = "Nexa", appContext: String? = nil) async -> IntentResult? {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else {
            usedOpenAI = false
            lastReason = "missing API key"
            return fallback.infer(from: text, agentName: agentName)
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let endpointURL: URL
        // Azure deployments usually ignore 'model' in body, but we pass it anyway or default to gpt-4o for standard OpenAI
        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        
        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                usedOpenAI = false
                lastReason = "invalid Azure URL"
                return fallback.infer(from: text, agentName: agentName)
            }
            
            // If the URL contains "deployments/...", we try to replace the deployment name with the chosen model
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            
            guard let scriptUrl = URL(string: azureString) else {
                usedOpenAI = false
                lastReason = "invalid Azure URL"
                return fallback.infer(from: text, agentName: agentName)
            }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if useAzure {
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
            // Azure 2024-12-01-preview + gpt-5.2/o1 models do NOT support max_tokens.
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let nowString = df.string(from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())
        let weekdayStr = Calendar.current.weekdaySymbols[weekday - 1]

        let userContext = (userName?.isEmpty == false) ? "The user's name is \(userName!)." : ""
        let contextBlock = (appContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? "\nAPP CONTEXT (from local app state):\n\(appContext!)\n"
            : ""
        
        let systemPrompt = """
        You are \(agentName), an intelligent personal assistant. \(userContext) The current time is \(nowString) (\(weekdayStr)).
        \(contextBlock)
        
        Your brain is powered by advanced AI. When you receive a request, THINK about what the user really wants.
        
        SUPPORTED CAPABILITIES:
        1. Manage Tasks (Action: 'task'): Add a task or scheduled reminder to the task list.
        2. Send SMS (Action: 'sendMessage'): Prepare a text message.
        3. Send Email (Action: 'sendEmail'): Prepare an email.
        4. Make Phone Call (Action: 'makePhoneCall'): Prepare a phone call.
        5. Answer/Chat (Action: 'answer'): Answer questions, chat, or explain limitations.
        6. Record Tracking Data (Action: 'track'): Record a value like spending or fitness for a tracking category.

        LOGIC RULES:
        1. GENERATIVE CONTENT:
           - If the user asks you to "message X a joke", "email Y a poem", "send a birthday wish", do NOT just set the body to "a joke" or "a poem".
           - You MUST generate the actual content in the 'messageBody' or 'callScript' field.
           - Example: "Message Ivy a joke" -> action='sendMessage', recipient='Ivy', messageBody='Why did the scarecrow win an award? Because he was outstanding in his field!'
        
        2. IMMEDIATE ACTIONS:
           - If the user starts with "message", "text", "email", "call" WITHOUT a specific future time, treat it as IMMEDIATE.
           - If the user wants to Send SMS, Email, or Call RIGHT NOW (e.g., "send message", "call mom", "email boss"): Return 'sendMessage', 'sendEmail', or 'makePhoneCall'.
              - If the user asks to organize/arrange/set up/schedule a meeting with someone, prefer action='sendEmail' (draft a meeting request email) unless they explicitly ask for only a reminder.
           - Default to IMMEDIATE action for communication commands unless a future time is explicitly mentioned (e.g. "tomorrow", "later", "at 5pm").
           - If the user wants ANY OTHER IMMEDIATE action (e.g., "play music", "open safari", "buy stocks", "set timer"): You DO NOT have these capabilities. Return action='answer' with answer="I don't have this capability yet."
        
        3. FUTURE ACTIONS / REMINDERS:
           - ONLY return action='task' if the user uses imperative verbs to command you to create something (e.g. "remind me to call later", "send text tomorrow", "add a task", "schedule a meeting").
           - ABSOLUTE OVERRIDE: If the user simply asks a QUESTION about their schedule (e.g. "how busy am I next week", "what is on my calendar tomorrow", "do I have any conflicts next week"), DO NOT return action='task' under any circumstances. THIS SHOULD ALWAYS BE action='answer'.
           - If the user explicitly asks to "remind" them or "add task" (e.g. "remind me to message X"): Return action='task', performer='user'.
           - IMPORTANT: For "remind me to call", set action='task' and performer='user' (unless they explicitly say "you call X tomorrow").
           - When calculating future dates (tomorrow, next week), use the current time (\(nowString) \(weekdayStr)) as the anchor.
        
        4. INQUIRIES / GREETINGS:
           - If the user greets you or asks a question: Return action='answer' with the response in 'answer'.
              - For action='answer', set 'title' to a short meaningful label (3-8 words) that summarizes the response topic.
              - If the user asks for summaries/status (e.g. "summarize today's tasks", "how busy am I next week", "what did I do today", "what notifications do I have"), use APP CONTEXT to answer concretely.
              - If the user asks about their schedule, calendar, conflicts, busyness or "how busy am I": you MUST return action='answer'. Do not create tasks or events from their inquiry. Look at UPCOMING tasks in APP CONTEXT to determine how busy they are, summarize those tasks, mention any conflicts naturally, and respond conversationally.
              - Never say you cannot access the data if APP CONTEXT is provided.
                  - Do NOT simulate in-app control flow in plain text (no “reply yes to open mail app” instructions). Use 'sendEmail' instead whenever email drafting + confirmation is needed.
        
        5. TRACKING:
           - If the user provides a value that seems like tracking a metric (e.g. "I spent 50$ on lunch", "just ran 5km", "my weight is 70kg"), return action='track'.
           - Extract the value as a number into 'trackingValue'.
           - Put the context (e.g. "lunch", "morning run") into 'trackingNote'.
           - Critically analyse the user's intent. Select the most semantically appropriate category from the TRACKING_CATEGORIES list in APP CONTEXT (for example, "petrol" or "lunch" clearly belongs to a "Spending" category). Provide its exact ID in 'trackingCategoryId'. If nothing logically matches, leave it null.
           
        6. CONTEXTUAL FOLLOW-UPS (Crucial for "yes/no" answers):
           - When the user replies with a simple "yes", "sure", or "do it", read the `RECENT_CHAT` in APP CONTEXT.
           - If the Agent recently asked "Would you like me to track/record this expense?" and the user said "yes", you MUST return action='track' and extract the value and category mentioned in the `RECENT_CHAT`. Do NOT return action='task'.
        
        JSON OUTPUT FORMAT:
        {
          "action": "task" | "sendMessage" | "sendEmail" | "makePhoneCall" | "answer" | "track",
          "title": "...",
          "startDate": "YYYY-MM-DD HH:mm",
          "dueDate": "YYYY-MM-DD HH:mm",
          "priority": 1-3,
          "tag": "...",
          "recipient": "...",
          "messageBody": "...",
          "subject": "...",
          "callScript": "...",
          "answer": "...",
          "performer": "user" | "agent",
          "isScheduled": true | false,
          "trackingCategoryId": "...",
          "trackingValue": 123.45,
          "trackingNote": "..."
        }
        
        Respond ONLY with valid JSON.
        """

        let userMessageContent: Any
        if let imageDataURL, !imageDataURL.isEmpty {
            userMessageContent = [
                ["type": "text", "text": text.isEmpty ? "Please analyze this image and respond based on what you see." : text],
                ["type": "image_url", "image_url": ["url": imageDataURL]]
            ]
        } else {
            userMessageContent = text
        }

        let body: [String: Any] = [
            "model": chosenModel,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessageContent]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let requestText = "\(systemPrompt)\n\nUser:\n\(text)\n\nHasImage:\(imageDataURL?.isEmpty == false)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logTokenUsage(feature: "intent_infer", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "no http response")
                usedOpenAI = false
                lastReason = "no http response"
                return fallback.infer(from: text, agentName: agentName)
            }
            guard 200..<300 ~= http.statusCode else {
                logTokenUsage(feature: "intent_infer", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "HTTP \(http.statusCode)")
                usedOpenAI = false
                lastReason = "HTTP \(http.statusCode)"
                return fallback.infer(from: text, agentName: agentName)
            }

            if let result = parseOpenAIResponse(data: data) {
                logTokenUsage(feature: "intent_infer", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
                usedOpenAI = true
                lastReason = "ok"
                return result
            } else {
                logTokenUsage(feature: "intent_infer", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse failure")
                usedOpenAI = false
                lastReason = "parse failure"
                return fallback.infer(from: text, agentName: agentName)
            }
        } catch {
            logTokenUsage(feature: "intent_infer", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
            usedOpenAI = false
            lastReason = "network/error"
            return fallback.infer(from: text, agentName: agentName)
        }
    }

    func streamAnswer(
        for text: String,
        imageDataURL: String? = nil,
        apiKey: String?,
        model: String?,
        useAzure: Bool,
        azureEndpoint: String?,
        userName: String?,
        agentName: String = "Nexa",
        appContext: String? = nil,
        onStreamEvent: (@MainActor () -> Void)? = nil,
        onDelta: @escaping @MainActor (String) -> Void
    ) async -> String? {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return nil }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        let endpointURL: URL

        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            guard let scriptUrl = URL(string: azureString) else { return nil }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if useAzure {
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let userContext = (userName?.isEmpty == false) ? "The user's name is \(userName!)." : ""
        let contextBlock = (appContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? "\nAPP CONTEXT:\n\(appContext!)\n"
            : ""

        let systemPrompt = """
        You are \(agentName), an intelligent personal assistant. \(userContext)
        Answer naturally and helpfully in plain text.
        Keep responses concise unless the user asks for detail.
        Use APP CONTEXT when provided and do not claim you cannot access it.
        \(contextBlock)
        """

        let userMessageContent: Any
        if let imageDataURL, !imageDataURL.isEmpty {
            userMessageContent = [
                ["type": "text", "text": text.isEmpty ? "Please analyze this image and answer the user request." : text],
                ["type": "image_url", "image_url": ["url": imageDataURL]]
            ]
        } else {
            userMessageContent = text
        }

        let body: [String: Any] = [
            "model": chosenModel,
            "temperature": 0.6,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessageContent]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let requestText = "answer_stream userText=\(text) hasImage=\(imageDataURL?.isEmpty == false)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                tokenUsageManager.addEntry(
                    feature: "answer_stream",
                    provider: provider,
                    model: chosenModel,
                    promptTokens: estimateTokens(for: requestText),
                    completionTokens: 0,
                    success: false,
                    errorReason: "no http response",
                    isEstimated: true
                )
                return nil
            }
            guard 200..<300 ~= http.statusCode else {
                tokenUsageManager.addEntry(
                    feature: "answer_stream",
                    provider: provider,
                    model: chosenModel,
                    promptTokens: estimateTokens(for: requestText),
                    completionTokens: 0,
                    success: false,
                    errorReason: "HTTP \(http.statusCode)",
                    isEstimated: true
                )
                return nil
            }

            var fullResponse = ""
            var didNotifyStreamStarted = false

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

                if payload == "[DONE]" {
                    break
                }

                if !didNotifyStreamStarted {
                    didNotifyStreamStarted = true
                    await onStreamEvent?()
                }

                guard let chunkData = payload.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let delta = first["delta"] as? [String: Any]
                else {
                    continue
                }

                if let content = delta["content"] as? String, !content.isEmpty {
                    fullResponse += content
                    await onDelta(fullResponse)
                    continue
                }

                if let contentParts = delta["content"] as? [[String: Any]] {
                    let joined = contentParts.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty {
                        fullResponse += joined
                        await onDelta(fullResponse)
                    }
                }
            }

            let finalText = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            let success = !finalText.isEmpty
            tokenUsageManager.addEntry(
                feature: "answer_stream",
                provider: provider,
                model: chosenModel,
                promptTokens: estimateTokens(for: requestText),
                completionTokens: estimateTokens(for: finalText),
                success: success,
                errorReason: success ? nil : "empty stream",
                isEstimated: true
            )

            return success ? finalText : nil
        } catch {
            tokenUsageManager.addEntry(
                feature: "answer_stream",
                provider: provider,
                model: chosenModel,
                promptTokens: estimateTokens(for: requestText),
                completionTokens: 0,
                success: false,
                errorReason: "network/error",
                isEstimated: true
            )
            return nil
        }
    }

    func classifyTaskTag(
        text: String,
        title: String?,
        apiKey: String?,
        model: String?,
        useAzure: Bool,
        azureEndpoint: String?,
        agentName: String = "Nexa"
    ) async -> String? {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return nil }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        let endpointURL: URL

        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            guard let scriptUrl = URL(string: azureString) else { return nil }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if useAzure {
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let systemPrompt = """
        You are \(agentName). Classify a task as one of:
        - Work
        - Personal
        Return JSON only: {"tag":"Work"} or {"tag":"Personal"}
        If uncertain, default to Personal.
        """

        let userPayload = "Task title: \(title ?? "")\nUser request: \(text)"
        let body: [String: Any] = [
            "model": chosenModel,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPayload]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let requestText = "task_tag_classify title=\(title ?? "") text=\(text)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                logTokenUsage(feature: "task_tag_classify", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "http")
                return nil
            }

            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let rawContent = message["content"] as? String
            else {
                logTokenUsage(feature: "task_tag_classify", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse")
                return nil
            }

            let content = stripCodeFences(rawContent)
            guard let contentData = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
                  let tagRaw = json["tag"] as? String
            else {
                logTokenUsage(feature: "task_tag_classify", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "missing-tag")
                return nil
            }

            logTokenUsage(feature: "task_tag_classify", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
            let lower = tagRaw.lowercased()
            if lower.contains("work") { return "Work" }
            if lower.contains("personal") { return "Personal" }
            return nil
        } catch {
            logTokenUsage(feature: "task_tag_classify", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
            return nil
        }
    }

    func parseRescheduleStartDate(
        from text: String,
        currentStart: Date,
        apiKey: String?,
        model: String?,
        useAzure: Bool,
        azureEndpoint: String?,
        agentName: String = "Nexa"
    ) async -> Date? {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return nil }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        let endpointURL: URL

        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            guard let scriptUrl = URL(string: azureString) else { return nil }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if useAzure {
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let reference = currentStart.formatted(date: .abbreviated, time: .shortened)
        let systemPrompt = """
        You are \(agentName). Extract the user's intended NEW start datetime for a task reschedule.
        Current task start is: \(reference).
        If user does not provide a new datetime, return hasDateTime=false.
        Return JSON only:
        {"hasDateTime": true|false, "startDate": "yyyy-MM-dd HH:mm"}
        """

        let body: [String: Any] = [
            "model": chosenModel,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let requestText = "reschedule_datetime_parse text=\(text)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                logTokenUsage(feature: "reschedule_datetime_parse", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "http")
                return nil
            }

            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let rawContent = message["content"] as? String
            else {
                logTokenUsage(feature: "reschedule_datetime_parse", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse")
                return nil
            }

            let content = stripCodeFences(rawContent)
            guard let contentData = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
                  let hasDateTime = json["hasDateTime"] as? Bool,
                  hasDateTime,
                  let startDateText = json["startDate"] as? String,
                  let parsedStart = parseFlexibleDate(startDateText)
            else {
                logTokenUsage(feature: "reschedule_datetime_parse", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "no-datetime")
                return nil
            }

            logTokenUsage(feature: "reschedule_datetime_parse", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
            return parsedStart
        } catch {
            logTokenUsage(feature: "reschedule_datetime_parse", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
            return nil
        }
    }

    func polishEmail(text: String, recipient: String, senderName: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, agentName: String = "Nexa") async -> (subject: String, body: String)? {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return nil }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        
        let endpointURL: URL
        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            guard let scriptUrl = URL(string: azureString) else { return nil }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if useAzure {
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let bodyPayload: [String: Any] = [
            "model": chosenModel,
            "temperature": 0.7,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "You are \(agentName), an intelligent assistant drafting an email to '\(recipient)' from '\(senderName)'. Based on the user's input, infer the relationship and tone (casual vs formal). If the user asks for creative content (e.g. 'send a joke', 'write a poem'), generate it appropriately. Construct the final email in JSON with 'subject' and 'body'. Ensure you sign off using '\(senderName)'."],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyPayload)
        let requestText = "email_polish recipient=\(recipient) sender=\(senderName) userText=\(text)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logTokenUsage(feature: "email_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "no http response")
                return nil
            }
            guard 200..<300 ~= http.statusCode else {
                logTokenUsage(feature: "email_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "HTTP \(http.statusCode)")
                return nil
            }
            
            struct EmailResponse: Decodable {
                let subject: String
                let body: String
            }
            
            // Reuse parseOpenAIResponse helper logic or just re-implement simple parsing here
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = result["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let contentRaw = msg["content"] as? String {
                   
                let content = stripCodeFences(contentRaw)
                if let jsonData = content.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let subj = dict["subject"] as? String,
                   let b = dict["body"] as? String {
                    logTokenUsage(feature: "email_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
                    return (subj, b)
                }
            }
            logTokenUsage(feature: "email_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse failure")
            return nil
        } catch {
            logTokenUsage(feature: "email_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
            return nil
        }
    }

    func polishMessage(text: String, history: String, recipient: String, senderName: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, agentName: String = "Nexa") async -> String? {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return nil }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
        
        let endpointURL: URL
        if useAzure {
            guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
            }
            guard let scriptUrl = URL(string: azureString) else { return nil }
            endpointURL = scriptUrl
        } else {
            endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if useAzure {
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let systemPrompt = """
        You are \(agentName), an intelligent assistant drafting a text message (SMS/iMessage) from '\(senderName)' to '\(recipient)'. 
        
        The user has been conversing with you. Here is the recent conversation context:
        ---
        \(history)
        ---
        
        The user's latest input regarding the message content is: "\(text)"
        
        Your task is to extract the intended message content from the user's spoken instruction and rewrite it for SMS.
        
        CRITICAL RULES:
        1. STRIP all instructional wrappers like "tell him", "ask her", "say that", "let them know", "text him that".
        2. GENERATE CONTENT: If the user asks to "send a joke", "write a poem", "wish happy birthday", or any other generative request, you MUST generate the actual creative content. Do not just repeat the request.
        3. The output must be the message itself, written in the first person (as if '\(senderName)' is typing it).
        4. Do NOT include phrases like "Here is the joke...", "He said...", "I should tell you...", or "The user wants me to say...".
        5. Polish the message to be concise and natural.
        6. USE CONTEXT: If the user refers to previous context (e.g., "tell him about that thing"), refer to the history to fill it in.
        
        Examples:
        - Input: "Tell him I'm running 5 mins late" -> Output: "I'm running 5 mins late"
        - Input: "Ask her if she wants to get dinner tonight" -> Output: "Do you want to get dinner tonight?"
        - Input: "Send a joke about programming" -> Output: "Why do programmers prefer dark mode? Because light attracts bugs!"
        - Input: "Wish him happy birthday with excitement" -> Output: "Happy Birthday!! 🎂 Hope you have an amazing day!"
        - Input: "Say that I love you" -> Output: "I love you"

        Return JSON with a single field "messageBody".
        """

        let bodyPayload: [String: Any] = [
            "model": chosenModel,
            "temperature": 0.7,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "The user input is: \"\(text)\""]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyPayload)
        let requestText = "message_polish recipient=\(recipient) sender=\(senderName) userText=\(text) history=\(history)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logTokenUsage(feature: "message_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "no http response")
                return nil
            }
            guard 200..<300 ~= http.statusCode else {
                logTokenUsage(feature: "message_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "HTTP \(http.statusCode)")
                return nil
            }
            
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = result["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let contentRaw = msg["content"] as? String {
                   
                let content = stripCodeFences(contentRaw)
                if let jsonData = content.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let body = dict["messageBody"] as? String {
                    logTokenUsage(feature: "message_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
                    return body
                }
            }
            logTokenUsage(feature: "message_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse failure")
            return nil
        } catch {
            logTokenUsage(feature: "message_polish", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
            return nil
        }
    }

    func checkEmailSufficiency(currentBody: String, recipient: String, senderName: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, agentName: String = "Nexa") async -> (sufficient: Bool, question: String?) {
         let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return (true, nil) }
         let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
         let chosenModel = model?.isEmpty == false ? model! : "gpt-4o"
         
         let endpointURL: URL
         if useAzure {
             guard var azureString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) else { return (true, nil) }
              if let range = azureString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                 azureString.replaceSubrange(range, with: "/deployments/\(chosenModel)/")
             }
             guard let scriptUrl = URL(string: azureString) else { return (true, nil) }
             endpointURL = scriptUrl
         } else {
             endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
         }
         
         var request = URLRequest(url: endpointURL)
         request.httpMethod = "POST"
         request.setValue("application/json", forHTTPHeaderField: "Content-Type")
         if useAzure {
             if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
         } else {
              request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
         }
         
         let sName = senderName.isEmpty ? "The User" : senderName
         let systemPrompt = """
         You are \(agentName), an intelligent assistant helping '\(sName)' write an email to '\(recipient)'. 
         Analyze the user's current raw notes: "\(currentBody)"
         
         1. Check if the notes are sufficient to write a COMPLETE email to THIS RECIPIENT.
         2. Infer the relationship (e.g. formal vs details).
         3. DO NOT ask who the recipient is, you already know it is '\(recipient)'.
         4. DO NOT ask for the sender's name if you think it is missing, just assume it will be signed by '\(sName)'.
         5. IMPORTANT: If the user says "I don't know", "not sure", "skip", "just write it", or implies they have no more info, RETURN TRUE immediately.
         6. Only ask for missing CRITICAL info (like time, place, specific purpose).
         
         - If sufficient (or user wants to stop), return JSON: {"sufficient": true}
         - If NOT sufficient, return JSON: {"sufficient": false, "question": "Your question here"}
         """
         
         let bodyPayload: [String: Any] = [
             "model": chosenModel,
             "temperature": 0.3,
             "response_format": ["type": "json_object"],
             "messages": [
                 ["role": "system", "content": systemPrompt]
             ]
         ]
         request.httpBody = try? JSONSerialization.data(withJSONObject: bodyPayload)
         let requestText = "email_sufficiency recipient=\(recipient) sender=\(sName) body=\(currentBody)"
         let provider = useAzure ? "azure-openai" : "openai"
         
         do {
             let (data, response) = try await session.data(for: request)
             guard let http = response as? HTTPURLResponse else {
                 logTokenUsage(feature: "email_sufficiency", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "no http response")
                 return (true, nil)
             }
             guard 200..<300 ~= http.statusCode else {
                 logTokenUsage(feature: "email_sufficiency", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "HTTP \(http.statusCode)")
                 return (true, nil)
             }
             
             if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = result["choices"] as? [[String: Any]],
                let first = choices.first,
                let msg = first["message"] as? [String: Any],
                let contentRaw = msg["content"] as? String {
                 
                 let content = stripCodeFences(contentRaw)
                 if let jsonData = content.data(using: .utf8),
                    let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                    let suff = dict["sufficient"] as? Bool {
                     let q = dict["question"] as? String
                     logTokenUsage(feature: "email_sufficiency", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
                     return (suff, q)
                 }
             }
             logTokenUsage(feature: "email_sufficiency", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse failure")
             return (true, nil)
         } catch {
             logTokenUsage(feature: "email_sufficiency", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
             return (true, nil)
         }
    }

    func testConnection(apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?) async -> String {
        let rawKey = apiKey ?? ""
        guard (!rawKey.isEmpty || useAzure) else { return "missing API key" }
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
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
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
        let requestText = "connection_test model=\(chosenModel)"
        let provider = useAzure ? "azure-openai" : "openai"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logTokenUsage(feature: "connection_test", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "no http response")
                return "no http response"
            }
            
            if !(200..<300 ~= http.statusCode) {
                if let errText = String(data: data, encoding: .utf8) {
                    print("Connection failed body: \(errText)")
                }
                logTokenUsage(feature: "connection_test", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "HTTP \(http.statusCode)")
                if http.statusCode == 429 {
                    return "Error 429 (Check Billing)"
                }
                return "HTTP \(http.statusCode)" 
            }
            let text = String(data: data, encoding: .utf8) ?? "no body"
            print("Response body: \(text)") 
            
            // 1. Try string match (relaxed)
            if text.contains("ok") && text.contains("true") {
                logTokenUsage(feature: "connection_test", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
                return "ok"
            }
            
            // 2. Try proper JSON parsing (more robust)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                   if content.contains("ok") && content.contains("true") {
                       logTokenUsage(feature: "connection_test", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: true)
                       return "ok"
                   }
            }
            
            logTokenUsage(feature: "connection_test", provider: provider, model: chosenModel, requestText: requestText, responseData: data, success: false, errorReason: "parse fail")
            return "parse fail"
        } catch {
            logTokenUsage(feature: "connection_test", provider: provider, model: chosenModel, requestText: requestText, responseData: nil, success: false, errorReason: "network/error")
            print("Network error: \(error)")
            return "network/error"
        }
    }

    private func logTokenUsage(feature: String, provider: String, model: String, requestText: String, responseData: Data?, success: Bool, errorReason: String? = nil) {
        if let parsed = extractTokenUsage(from: responseData) {
            tokenUsageManager.addEntry(
                feature: feature,
                provider: provider,
                model: model,
                promptTokens: parsed.promptTokens,
                completionTokens: parsed.completionTokens,
                success: success,
                errorReason: errorReason,
                isEstimated: false
            )
            return
        }

        let estimatedPrompt = estimateTokens(for: requestText)
        let estimatedCompletion = success ? estimateTokens(for: extractResponseMessage(from: responseData) ?? "") : 0

        tokenUsageManager.addEntry(
            feature: feature,
            provider: provider,
            model: model,
            promptTokens: estimatedPrompt,
            completionTokens: estimatedCompletion,
            success: success,
            errorReason: errorReason,
            isEstimated: true
        )
    }

    private func extractTokenUsage(from data: Data?) -> (promptTokens: Int, completionTokens: Int)? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { return nil }

        let prompt = intValue(from: usage, keys: ["prompt_tokens", "input_tokens", "promptTokenCount", "inputTokenCount"])
        let completion = intValue(from: usage, keys: ["completion_tokens", "output_tokens", "completionTokenCount", "outputTokenCount"])
        let total = intValue(from: usage, keys: ["total_tokens", "totalTokenCount"])

        if prompt == 0, completion == 0, total == 0 {
            return nil
        }

        if prompt == 0, completion == 0, total > 0 {
            return (total, 0)
        }

        if total > 0, prompt == 0 {
            return (max(0, total - completion), completion)
        }

        if total > 0, completion == 0 {
            return (prompt, max(0, total - prompt))
        }

        return (prompt, completion)
    }

    private func intValue(from dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = dict[key] as? Int {
                return value
            }
            if let value = dict[key] as? Double {
                return Int(value)
            }
            if let value = dict[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return 0
    }

    private func estimateTokens(for text: String) -> Int {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return 0 }
        return max(1, cleaned.count / 4)
    }

    private func extractResponseMessage(from data: Data?) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }

        return stripCodeFences(content)
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
        let callScript = dict["callScript"] as? String
        let subject = dict["subject"] as? String
        let answer = dict["answer"] as? String
        
        // Delegation
        let performer = dict["performer"] as? String ?? "user"
        // Heuristic: if dates are present and action is not 'task', it might be scheduled
        let startDateStr = dict["startDate"] as? String
        let isScheduled = (startDateStr != nil)

        // Tracking
        let trackingCategoryId = dict["trackingCategoryId"] as? String
        var trackingValue: Double? = nil
        if let val = dict["trackingValue"] as? Double {
            trackingValue = val
        } else if let val = dict["trackingValue"] as? Int {
            trackingValue = Double(val)
        } else if let valStr = dict["trackingValue"] as? String {
            let replaced = valStr.replacingOccurrences(of: "$", with: "")
                                 .replacingOccurrences(of: "£", with: "")
                                 .replacingOccurrences(of: "€", with: "")
                                 .trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = Double(replaced) { trackingValue = val }
        }
        let trackingNote = dict["trackingNote"] as? String

        func parseDate(_ value: Any?) -> Date? {
            guard let s = value as? String else { return nil }
            if let iso = ISO8601DateFormatter().date(from: s) { return iso }
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .gregorian)
            df.timeZone = .current
            df.locale = .current
            df.dateFormat = "yyyy-MM-dd HH:mm"
            if let d = df.date(from: s) { return d }
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
                messageBody: messageBody,
                performer: performer,
                isScheduled: isScheduled
            )
        }

        return IntentResult(
            title: title ?? "New Task",
            startDate: start,
            dueDate: due,
            priority: min(max(priority, 1), 3),
            tag: tag,
            action: action,
            recipient: recipient,
            messageBody: messageBody,
            subject: subject,
            callScript: callScript,
            answer: answer,
            performer: performer,
            isScheduled: isScheduled,
            trackingCategoryId: trackingCategoryId,
            trackingValue: trackingValue,
            trackingNote: trackingNote
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

    private func parseFlexibleDate(_ value: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: value) { return iso }

        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = .current
        df.locale = .current

        let formats = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]

        for format in formats {
            df.dateFormat = format
            if let date = df.date(from: value) {
                return date
            }
        }

        return nil
    }
}

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let isUser: Bool
    let text: String
    let timestamp: Date
    let taskStatusSnapshot: TaskStatusSnapshot?
    let responseTitle: String?

    init(id: UUID = UUID(), isUser: Bool, text: String, timestamp: Date = .init(), taskStatusSnapshot: TaskStatusSnapshot? = nil, responseTitle: String? = nil) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.timestamp = timestamp
        self.taskStatusSnapshot = taskStatusSnapshot
        self.responseTitle = responseTitle
    }
}

struct TaskStatusSnapshot: Hashable, Codable {
    let completed: Int
    let overdue: Int
    let upcoming: Int
    let completedWork: Int
    let completedPersonal: Int
    let completedOther: Int
    let overdueWork: Int
    let overduePersonal: Int
    let overdueOther: Int
    let upcomingWork: Int
    let upcomingPersonal: Int
    let upcomingOther: Int

    init(
        completed: Int,
        overdue: Int,
        upcoming: Int,
        completedWork: Int = 0,
        completedPersonal: Int = 0,
        completedOther: Int = 0,
        overdueWork: Int = 0,
        overduePersonal: Int = 0,
        overdueOther: Int = 0,
        upcomingWork: Int = 0,
        upcomingPersonal: Int = 0,
        upcomingOther: Int = 0
    ) {
        self.completed = completed
        self.overdue = overdue
        self.upcoming = upcoming
        self.completedWork = completedWork
        self.completedPersonal = completedPersonal
        self.completedOther = completedOther
        self.overdueWork = overdueWork
        self.overduePersonal = overduePersonal
        self.overdueOther = overdueOther
        self.upcomingWork = upcomingWork
        self.upcomingPersonal = upcomingPersonal
        self.upcomingOther = upcomingOther
    }

    private enum CodingKeys: String, CodingKey {
        case completed
        case overdue
        case upcoming
        case completedWork
        case completedPersonal
        case completedOther
        case overdueWork
        case overduePersonal
        case overdueOther
        case upcomingWork
        case upcomingPersonal
        case upcomingOther
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = try container.decode(Int.self, forKey: .completed)
        overdue = try container.decode(Int.self, forKey: .overdue)
        upcoming = try container.decode(Int.self, forKey: .upcoming)
        completedWork = try container.decodeIfPresent(Int.self, forKey: .completedWork) ?? 0
        completedPersonal = try container.decodeIfPresent(Int.self, forKey: .completedPersonal) ?? 0
        completedOther = try container.decodeIfPresent(Int.self, forKey: .completedOther) ?? completed
        overdueWork = try container.decodeIfPresent(Int.self, forKey: .overdueWork) ?? 0
        overduePersonal = try container.decodeIfPresent(Int.self, forKey: .overduePersonal) ?? 0
        overdueOther = try container.decodeIfPresent(Int.self, forKey: .overdueOther) ?? overdue
        upcomingWork = try container.decodeIfPresent(Int.self, forKey: .upcomingWork) ?? 0
        upcomingPersonal = try container.decodeIfPresent(Int.self, forKey: .upcomingPersonal) ?? 0
        upcomingOther = try container.decodeIfPresent(Int.self, forKey: .upcomingOther) ?? upcoming
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(completed, forKey: .completed)
        try container.encode(overdue, forKey: .overdue)
        try container.encode(upcoming, forKey: .upcoming)
        try container.encode(completedWork, forKey: .completedWork)
        try container.encode(completedPersonal, forKey: .completedPersonal)
        try container.encode(completedOther, forKey: .completedOther)
        try container.encode(overdueWork, forKey: .overdueWork)
        try container.encode(overduePersonal, forKey: .overduePersonal)
        try container.encode(overdueOther, forKey: .overdueOther)
        try container.encode(upcomingWork, forKey: .upcomingWork)
        try container.encode(upcomingPersonal, forKey: .upcomingPersonal)
        try container.encode(upcomingOther, forKey: .upcomingOther)
    }
}

extension ChatMessage: Codable {}

extension Notification.Name {
    static let chatHistoryDidImport = Notification.Name("chatHistoryDidImport")
}

struct ChatHistoryBackupPayload: Codable {
    let version: Int
    let exportedAt: Date
    let messages: [ChatMessage]
}

struct ChatHistoryBackupPayloadV2: Codable {
    let version: Int
    let exportedAt: Date
    let records: [EmbeddedChatRecord]
}

struct EmbeddedChatRecord: Codable {
    let message: ChatMessage
    let embeddingModel: String?
    let embeddedAt: Date?
    let textHash: String
}

struct StatusCategoryRow: Identifiable {
    let id = UUID()
    let status: String
    let category: String
    let count: Int
}

struct SavedAgentItem: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var createdAt: Date = .now
    var savedAt: Date = .now
    var sourceMessageID: UUID? = nil

    static func titleFrom(content: String) -> String {
        let fallback = "Saved response"
        let firstLine = content
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        guard let firstLine, !firstLine.isEmpty else { return fallback }
        if firstLine.count <= 70 { return firstLine }
        let clipped = firstLine.prefix(67).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clipped)..."
    }

    var shareText: String {
        "\(title)\n\n\(content)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case createdAt
        case savedAt
        case sourceMessageID
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        createdAt: Date = .now,
        savedAt: Date = .now,
        sourceMessageID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.sourceMessageID = sourceMessageID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? createdAt
        sourceMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceMessageID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encodeIfPresent(sourceMessageID, forKey: .sourceMessageID)
    }
}

struct ChatSessionArchive: Codable {
    let id: UUID
    let createdAt: Date
    let endedAt: Date
    let records: [EmbeddedChatRecord]
}

@MainActor
final class ChatHistoryStore {
    static let shared = ChatHistoryStore()

    private let storageKey = "chat_history_v1"
    private let sessionsStorageKey = "chat_history_sessions_v1"
    private let maxStoredMessages = 300
    private let maxStoredSessions = 40
    private var saveTask: Task<Void, Never>?

    private init() {}

    func loadMessages() -> [ChatMessage] {
        return loadStoredRecords().map(\.message)
    }

    func saveMessages(_ messages: [ChatMessage]) {
        let trimmed = Array(messages.suffix(maxStoredMessages))
        saveTask?.cancel()
        saveTask = Task { [weak self, trimmed] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            self.persistMessages(trimmed)
        }
    }

    func flushMessages(_ messages: [ChatMessage]) {
        saveTask?.cancel()
        let trimmed = Array(messages.suffix(maxStoredMessages))
        persistMessages(trimmed)
    }

    func archiveCurrentSession(_ messages: [ChatMessage]) {
        let meaningful = messages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !meaningful.isEmpty else { return }

        let records = records(from: meaningful)
        guard !records.isEmpty else { return }

        let createdAt = meaningful.first?.timestamp ?? Date()
        let endedAt = meaningful.last?.timestamp ?? Date()
        let archive = ChatSessionArchive(id: UUID(), createdAt: createdAt, endedAt: endedAt, records: records)

        var sessions = loadSessionArchives()
        sessions.append(archive)
        if sessions.count > maxStoredSessions {
            sessions = Array(sessions.suffix(maxStoredSessions))
        }
        persistSessionArchives(sessions)
    }

    func clearCurrentSession() {
        saveTask?.cancel()
        persistRecords([])
    }

    func clearAllHistory() {
        saveTask?.cancel()
        persistRecords([])
        persistSessionArchives([])
        NotificationCenter.default.post(name: .chatHistoryDidImport, object: nil)
    }

    func chatHistoryStorageSizeBytes() -> Int {
        let currentSessionBytes = UserDefaults.standard.data(forKey: storageKey)?.count ?? 0
        let archivedSessionsBytes = UserDefaults.standard.data(forKey: sessionsStorageKey)?.count ?? 0
        return currentSessionBytes + archivedSessionsBytes
    }

    func testEmbeddingConnection(apiKey: String?, model: String?, useAzure: Bool? = nil, azureEndpoint: String? = nil) async -> String {
        let config = resolvedEmbeddingConfig(
            overrideApiKey: apiKey,
            overrideModel: model,
            overrideUseAzure: useAzure,
            overrideAzureEndpoint: azureEndpoint
        )
        guard (!config.apiKey.isEmpty || config.useAzure) else { return "missing API key" }

        guard let request = makeEmbeddingRequest(
            text: "embedding connection test",
            model: config.model,
            apiKey: config.apiKey,
            useAzure: config.useAzure,
            azureEndpoint: config.azureEndpoint
        ) else {
            return "invalid endpoint"
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "no http response"
            }
            guard 200..<300 ~= http.statusCode else {
                return "HTTP \(http.statusCode)"
            }

            struct EmbeddingResponse: Decodable {
                struct Item: Decodable {
                    let embedding: [Double]
                }
                let data: [Item]
            }

            let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
            return decoded.data.first?.embedding.isEmpty == false ? "ok" : "empty embedding"
        } catch {
            return "network/error"
        }
    }

    func exportBackupData() throws -> Data {
        let payload = ChatHistoryBackupPayloadV2(version: 2, exportedAt: Date(), records: loadStoredRecords())
        return try JSONEncoder().encode(payload)
    }

    @discardableResult
    func importBackupData(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()

        if let payloadV2 = try? decoder.decode(ChatHistoryBackupPayloadV2.self, from: data) {
            persistRecords(payloadV2.records)
            NotificationCenter.default.post(name: .chatHistoryDidImport, object: nil)
            return payloadV2.records.count
        }

        if let payload = try? decoder.decode(ChatHistoryBackupPayload.self, from: data) {
            let records = payload.messages.map { message in
                EmbeddedChatRecord(
                    message: message,
                    embeddingModel: nil,
                    embeddedAt: nil,
                    textHash: textHash(for: message.text)
                )
            }
            persistRecords(records)
            NotificationCenter.default.post(name: .chatHistoryDidImport, object: nil)
            return payload.messages.count
        }

        let directMessages = try decoder.decode([ChatMessage].self, from: data)
        let records = directMessages.map { message in
            EmbeddedChatRecord(
                message: message,
                embeddingModel: nil,
                embeddedAt: nil,
                textHash: textHash(for: message.text)
            )
        }
        persistRecords(records)
        NotificationCenter.default.post(name: .chatHistoryDidImport, object: nil)
        return directMessages.count
    }

    private func persistMessages(_ messages: [ChatMessage]) {
        let output = records(from: messages)
        persistRecords(output)
    }

    private func records(from messages: [ChatMessage]) -> [EmbeddedChatRecord] {
        let existingById = Dictionary(uniqueKeysWithValues: loadStoredRecords().map { ($0.message.id, $0) })
        var output: [EmbeddedChatRecord] = []
        output.reserveCapacity(messages.count)

        for message in messages {
            let hash = textHash(for: message.text)
            if let existing = existingById[message.id], existing.textHash == hash {
                output.append(existing)
                continue
            }
            output.append(
                EmbeddedChatRecord(
                    message: message,
                    embeddingModel: nil,
                    embeddedAt: nil,
                    textHash: hash
                )
            )
        }

        return output
    }

    private func loadStoredRecords() -> [EmbeddedChatRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        let decoder = JSONDecoder()

        if let records = try? decoder.decode([EmbeddedChatRecord].self, from: data) {
            let trimmed = Array(records.suffix(maxStoredMessages))
            if records.count != trimmed.count || data.count > 1_000_000 {
                persistRecords(trimmed)
            }
            return trimmed
        }

        if let legacyMessages = try? decoder.decode([ChatMessage].self, from: data) {
            let trimmed = Array(legacyMessages.suffix(maxStoredMessages)).map {
                EmbeddedChatRecord(
                    message: $0,
                    embeddingModel: nil,
                    embeddedAt: nil,
                    textHash: textHash(for: $0.text)
                )
            }
            persistRecords(trimmed)
            return trimmed
        }

        return []
    }

    private func persistRecords(_ records: [EmbeddedChatRecord]) {
        let trimmed = Array(records.suffix(maxStoredMessages))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func loadSessionArchives() -> [ChatSessionArchive] {
        guard let data = UserDefaults.standard.data(forKey: sessionsStorageKey),
              let decoded = try? JSONDecoder().decode([ChatSessionArchive].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func persistSessionArchives(_ sessions: [ChatSessionArchive]) {
        let trimmed = Array(sessions.suffix(maxStoredSessions))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: sessionsStorageKey)
    }

    private func resolvedEmbeddingConfig(
        overrideApiKey: String? = nil,
        overrideModel: String? = nil,
        overrideUseAzure: Bool? = nil,
        overrideAzureEndpoint: String? = nil
    ) -> (apiKey: String, model: String, useAzure: Bool, azureEndpoint: String?) {
        let env = ProcessInfo.processInfo.environment

        let directApiKey = overrideApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let envApiKey = env["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedApiKey = UserDefaults.standard.string(forKey: "OPENAI_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (directApiKey?.isEmpty == false ? directApiKey : nil)
            ?? (envApiKey?.isEmpty == false ? envApiKey : nil)
            ?? (storedApiKey?.isEmpty == false ? storedApiKey : nil)
            ?? ""

        let directModel = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let envEmbeddingModel = env["OPENAI_EMBEDDING_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedEmbeddingModel = UserDefaults.standard.string(forKey: "OPENAI_EMBEDDING_MODEL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (directModel?.isEmpty == false ? directModel : nil)
            ?? (envEmbeddingModel?.isEmpty == false ? envEmbeddingModel : nil)
            ?? (storedEmbeddingModel?.isEmpty == false ? storedEmbeddingModel : nil)
            ?? "text-embedding-3-small"

        let envUseAzureRaw = env["OPENAI_USE_AZURE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let envUseAzure = (envUseAzureRaw == "1" || envUseAzureRaw == "true" || envUseAzureRaw == "yes")
        let storedUseAzure = UserDefaults.standard.bool(forKey: "OPENAI_USE_AZURE")
        let useAzure = overrideUseAzure ?? envUseAzure || storedUseAzure

        let directAzureEndpoint = overrideAzureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let envAzureEndpoint = env["OPENAI_AZURE_EMBEDDING_ENDPOINT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedAzureEndpoint = UserDefaults.standard.string(forKey: "OPENAI_AZURE_EMBEDDING_ENDPOINT")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAzureEndpoint = UserDefaults.standard.string(forKey: "OPENAI_AZURE_ENDPOINT")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let azureEndpoint = (directAzureEndpoint?.isEmpty == false ? directAzureEndpoint : nil)
            ?? (envAzureEndpoint?.isEmpty == false ? envAzureEndpoint : nil)
            ?? (storedAzureEndpoint?.isEmpty == false ? storedAzureEndpoint : nil)
            ?? (fallbackAzureEndpoint?.isEmpty == false ? fallbackAzureEndpoint : nil)

        return (apiKey, model, useAzure, azureEndpoint)
    }

    private func textHash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fetchEmbedding(text: String, model: String, apiKey: String, useAzure: Bool, azureEndpoint: String?) async -> [Double]? {
        guard !apiKey.isEmpty else { return nil }
        guard let request = makeEmbeddingRequest(text: text, model: model, apiKey: apiKey, useAzure: useAzure, azureEndpoint: azureEndpoint) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }

            struct EmbeddingResponse: Decodable {
                struct Item: Decodable {
                    let embedding: [Double]
                }
                let data: [Item]
            }

            let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
            return decoded.data.first?.embedding
        } catch {
            return nil
        }
    }

    private func makeEmbeddingRequest(text: String, model: String, apiKey: String, useAzure: Bool, azureEndpoint: String?) -> URLRequest? {
        let request: URLRequest

        if useAzure {
            guard let endpointString = azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
                  var components = URLComponents(string: endpointString),
                  let host = components.host
            else {
                return nil
            }

            let lowerHost = host.lowercased()
            guard lowerHost.contains("openai.azure.com") || lowerHost.contains("cognitiveservices.azure.com") || lowerHost.contains("azure-api.net") else {
                return nil
            }

            let apiVersion = components.queryItems?.first(where: { $0.name.lowercased() == "api-version" })?.value ?? "2024-12-01-preview"

            if var pathString = components.string, let range = pathString.range(of: "/deployments/[^/]+/", options: .regularExpression) {
                pathString.replaceSubrange(range, with: "/deployments/\(model)/")
                if let updatedComponents = URLComponents(string: pathString) {
                    components.path = updatedComponents.path
                }
            } else if components.path.hasSuffix("/chat/completions") {
                components.path = components.path.replacingOccurrences(of: "/chat/completions", with: "/embeddings")
            } else if !components.path.contains("/embeddings") {
                components.path = "/openai/deployments/\(model)/embeddings"
            }

            components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]

            guard let azureURL = components.url else { return nil }
            var azureRequest = URLRequest(url: azureURL)
            azureRequest.httpMethod = "POST"
            azureRequest.timeoutInterval = 30
            azureRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                azureRequest.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
            let body: [String: Any] = [
                "model": model,
                "input": text
            ]
            azureRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request = azureRequest
            return request
        } else {
            guard let openAIURL = URL(string: "https://api.openai.com/v1/embeddings") else { return nil }
            var openAIRequest = URLRequest(url: openAIURL)
            openAIRequest.httpMethod = "POST"
            openAIRequest.timeoutInterval = 30
            openAIRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            openAIRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": model,
                "input": text
            ]
            openAIRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request = openAIRequest
            return request
        }
    }
}

struct TaskDraft: Equatable {
    var title: String
    var startDate: Date = .now
    var dueDate: Date = .now.addingTimeInterval(60 * 60 * 24)
    var priority: Int = 1
    var tag: String = "Inbox"
}

struct MessageDraft {
    var recipient: String = ""
    var body: String = ""
}

struct PendingAttachment: Equatable {
    var fileName: String
    var fileSizeBytes: Int
    var fileTypeIdentifier: String
    var pixelWidth: Int?
    var pixelHeight: Int?
    var thumbnailJPEGData: Data?
    var visionImageDataURL: String?

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file)
    }

    var imageResolutionLabel: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth)×\(pixelHeight)"
    }
}

struct EmailDraft: Equatable {
    var recipient: String = ""
    var recipientName: String = ""
    var subject: String = ""
    var body: String = ""
}

enum InteractionState: Equatable {
    case idle
    case collectingMessageRecipient
    case collectingMessageBody
    case collectingCallRecipient // New case
    case collectingEmailRecipient
    case collectingEmailAddress
    case collectingEmailBody
    case collectingUserName 
    case answeringEmailQuestion
    case confirmingEmail(EmailDraft)
    case clarifyingContact(candidates: [SimpleContact], forCall: Bool, forEmail: Bool)
    case verifyingEmailContact(contact: SimpleContact)
    case collectingEmailAddressForContact(contact: SimpleContact)
    case offeringToSaveEmail(contact: SimpleContact, email: String)
    case resolvingMissingTaskContact(task: TaskItem, missingType: String)
    case collectingNewContactDetail(task: TaskItem, name: String, missingType: String)
    case collectingScheduledTaskContact(name: String, missingType: String, draft: TaskDraft, actionType: String)
    case collectingScheduledActionContent(draft: TaskDraft, actionType: String, recipient: String, promptLabel: String)
    case confirmingTaskConflict(draft: TaskDraft, actionPayload: TaskItem.AgentAction?, conflicts: [TaskItem], suggestions: [Date])
    case collectingConflictDateTime(draft: TaskDraft, actionPayload: TaskItem.AgentAction?)
    case confirmingTrackingRequest(categoryId: UUID, categoryName: String, value: Double, note: String?, rawText: String?, recordDate: Date)
}

struct SimpleContact: Identifiable, Hashable {
    var id = UUID()
    var contactId: String? // Added for updates
    var name: String
    var number: String
    var email: String?
    var label: String
}

class ContactHelpers {
    private let store = CNContactStore()
    
    func createContact(name: String, phone: String?, email: String?) async -> Bool {
        guard await requestAccess() else { return false }
        let contact = CNMutableContact()
        let nameParts = name.components(separatedBy: " ")
        contact.givenName = nameParts.first ?? name
        if nameParts.count > 1 {
            contact.familyName = nameParts.dropFirst().joined(separator: " ")
        }
        
        if let p = phone, !p.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: p))]
        }
        if let e = email, !e.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: e as NSString)]
        }
        
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            return true
        } catch {
            print("Error creating contact: \(error)")
            return false
        }
    }
    
    func requestAccess() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }
    
    func saveEmail(to contactId: String, email: String, label: String = "Email") async -> Bool {
        guard await requestAccess() else { return false }
        do {
            // Need to fetch the mutable contact
            let keys = [CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let contact = try store.unifiedContact(withIdentifier: contactId, keysToFetch: keys).mutableCopy() as! CNMutableContact
            
            let emailValue = CNLabeledValue(label: label, value: email as NSString)
            contact.emailAddresses.append(emailValue)
            
            let saveRequest = CNSaveRequest()
            saveRequest.update(contact)
            try store.execute(saveRequest)
            return true
        } catch {
            print("Error saving email: \(error)")
            return false
        }
    }
    
    func find(name: String) async -> [SimpleContact] {
        guard await requestAccess() else { return [] }
        
        // We will try a few strategies:
        // 1. Exact/Prefix match using CNContact predicate (fastest)
        // 2. If that fails or user wants more, we might need a broader search, but CNContact doesn't support fuzzy search well.
        // We will rely on the predicate for now, but we can fetch ALL contacts and filter if the predicate returns nothing.
        // Fetching all contacts is heavy, so let's stick to the predicate first.
        
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        
        do {
            var contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            
            // If strict search failed, try fetching all and fuzzy matching (expensive but powerful)
            if contacts.isEmpty {
                 let allContainers = try store.containers(matching: nil)
                 for container in allContainers {
                     let fetchPredicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
                     let allContacts = try store.unifiedContacts(matching: fetchPredicate, keysToFetch: keys)
                     // Filter manually
                     let networkingMatches = allContacts.filter { c in
                         let first = c.givenName.lowercased()
                         let last = c.familyName.lowercased()
                         let query = name.lowercased()
                         return first.contains(query) || last.contains(query)
                     }
                     contacts.append(contentsOf: networkingMatches)
                     // Limit to avoid freezing
                     if contacts.count > 20 { break }
                 }
            }
            
            var results: [SimpleContact] = []
            
            for c in contacts {
                let fullName = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
                var pushed = false
                
                // Add phone entries
                for num in c.phoneNumbers {
                    results.append(SimpleContact(
                        contactId: c.identifier,
                        name: fullName,
                        number: num.value.stringValue,
                        email: nil,
                        label: CNLabeledValue<NSString>.localizedString(forLabel: num.label ?? "Mobile")
                    ))
                    pushed = true
                }
                
                // Add email entries
                for email in c.emailAddresses {
                    results.append(SimpleContact(
                        contactId: c.identifier,
                        name: fullName,
                        number: "",
                        email: email.value as String,
                        label: CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "Email")
                    ))
                    pushed = true
                }
                
                // Fallback if no details
                if !pushed {
                    results.append(SimpleContact(
                        contactId: c.identifier,
                        name: fullName,
                        number: "",
                        email: nil,
                        label: "Contact"
                    ))
                }
            }
            // Dedup by unique properties to be safe
            return Array(Set(results))
        } catch {
            return []
        }
    }

    func getMeCardName() async -> String? {
        // Ensure we have permission first
        guard await requestAccess() else { return nil }
        
        #if os(iOS)
        // Access UIDevice on the main thread before detaching
        let deviceName = UIDevice.current.name
        #else
        let deviceName = "" 
        #endif

        // Run on background thread to avoid Main Thread checker warnings for ContactStore
        return await Task.detached(priority: .userInitiated) { [deviceName] in
            let store = CNContactStore()
            
            #if os(macOS)
            do {
                let me = try store.unifiedMeContactWithKeys(toFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor])
                let name = "\(me.givenName) \(me.familyName)".trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            } catch {
                return nil
            }
            #else
            // iOS Fallback:
            // Attempt to infer from device name (e.g. "John's iPhone"), then finding a contact with that name.
            let devName = deviceName
            var searchName: String?
            
            if let range = devName.range(of: " iPhone") ?? devName.range(of: "'s iPhone") {
                let candidate = String(devName[..<range.lowerBound])
                if candidate.hasSuffix("’s") {
                    searchName = String(candidate.dropLast(2))
                } else if candidate.hasSuffix("'s") {
                    searchName = String(candidate.dropLast(2))
                } else {
                    searchName = candidate
                }
            }
            
            guard let nameToFind = searchName, !nameToFind.isEmpty else { return nil }
            
            do {
                let predicate = CNContact.predicateForContacts(matchingName: nameToFind)
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
                let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
                
                // If we found exactly one match, great.
                // If multiple, hard to say which one is 'me'. We'll just return the first one as a best guess
                // or return the searchName itself if no contacts found.
                if let first = contacts.first {
                    let fullName = "\(first.givenName) \(first.familyName)".trimmingCharacters(in: .whitespaces)
                    return fullName.isEmpty ? nameToFind : fullName
                }
                return nameToFind
            } catch {
                return nameToFind
            }
            #endif
        }.value
    }
    
    func findTop5(query: String) async -> [SimpleContact] {
        guard await requestAccess() else { return [] }
        
        // This is a naive 'top 5' implementation that fetches all contacts and filters
        // In a real app with 10k contacts, this is slow. Use with caution.
        do {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var allContacts: [CNContact] = []
            
            // Fetch all (filtering in memory because predicate only supports exact/prefix)
            let request = CNContactFetchRequest(keysToFetch: keys)
            try store.enumerateContacts(with: request) { (contact, stop) in
                allContacts.append(contact)
            }
            
            let lowerQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Score and sort
            struct ScoredContact {
                let contact: CNContact
                let score: Int
            }
            
            let scored = allContacts.compactMap { c -> ScoredContact? in
                let first = c.givenName.lowercased()
                let last = c.familyName.lowercased()
                let full = "\(first) \(last)"
                
                var score = 0
                if full == lowerQuery { score += 100 }
                else if first == lowerQuery { score += 90 }
                else if last == lowerQuery { score += 80 }
                else if full.starts(with: lowerQuery) { score += 60 }
                else if first.starts(with: lowerQuery) { score += 50 }
                else if last.starts(with: lowerQuery) { score += 40 }
                else if full.contains(lowerQuery) { score += 20 }
                else { return nil }
                
                return ScoredContact(contact: c, score: score)
            }
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { $0.contact }
            
            var results: [SimpleContact] = []
            for c in scored {
                let fullName = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
                
                for num in c.phoneNumbers {
                    results.append(SimpleContact(
                        contactId: c.identifier,
                        name: fullName,
                        number: num.value.stringValue,
                        email: nil,
                        label: CNLabeledValue<NSString>.localizedString(forLabel: num.label ?? "Mobile")
                    ))
                }
                for email in c.emailAddresses {
                    results.append(SimpleContact(
                        contactId: c.identifier,
                        name: fullName,
                        number: "",
                        email: email.value as String,
                        label: CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "Email")
                    ))
                }
            }
            // Dedup by hashable
            return Array(Set(results))
        } catch {
            return []
        }
    }
}

// MARK: - Speech recognizer

@MainActor
final class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {
    @Published var transcript: String = ""
    @Published var isRecording = false
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    
    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    private var wasRecordingBeforeSpeaking = false
    
    // Silence Detection
    private var silenceTimer: Timer?
    var onSilence: (() -> Void)?

    override init() {
        super.init()
        recognizer?.delegate = self
        synthesizer.delegate = self
        // Setup initial audio session
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    }
    
    func speak(_ text: String, voiceIdentifier: String? = nil) {
        // Stop recording if active to prevent self-capture
        if isRecording {
            wasRecordingBeforeSpeaking = true
            stopRecording() // This also invalidates silence timer
        } else {
            wasRecordingBeforeSpeaking = false
        }
        
        // Quick cleanup of text for speech (optional)
        let clean = text.replacingOccurrences(of: "sms:", with: "message link")
            
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        
        let utterance = AVSpeechUtterance(string: clean)
        if let identifier = voiceIdentifier,
           !identifier.isEmpty,
           let configuredVoice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = configuredVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Resume listening if we were recording before
            if self.wasRecordingBeforeSpeaking {
                self.startRecording()
                self.wasRecordingBeforeSpeaking = false
            } else {
                // If we weren't recording, we still might want to reset session
                 try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
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
                    // Reset Silence Timer
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                         guard let self = self, self.isRecording else { return }
                         self.onSilence?()
                    }
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopRecording()
            }
        }
    }

    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        task?.cancel()
        task = nil
        
        audioEngine.stop()
        request?.endAudio()
        request = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum LocationLookupError: Error {
    case denied
    case unavailable
    case inProgress
}

@MainActor
final class UserLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = UserLocationProvider()

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentLocation() async throws -> CLLocation {
        if locationContinuation != nil {
            throw LocationLookupError.inProgress
        }

        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            throw LocationLookupError.denied
        }

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            let currentStatus = manager.authorizationStatus
            if currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    func requestWhenInUseAuthorization() async -> Bool {
        let status = manager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                self.authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if let continuation = authorizationContinuation {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                authorizationContinuation = nil
                continuation.resume(returning: true)
            case .denied, .restricted:
                authorizationContinuation = nil
                continuation.resume(returning: false)
            case .notDetermined:
                break
            @unknown default:
                authorizationContinuation = nil
                continuation.resume(returning: false)
            }
        }

        guard let continuation = locationContinuation else { return }

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            locationContinuation = nil
            continuation.resume(throwing: LocationLookupError.denied)
        case .notDetermined:
            break
        @unknown default:
            locationContinuation = nil
            continuation.resume(throwing: LocationLookupError.unavailable)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil

        if let best = locations.last {
            continuation.resume(returning: best)
        } else {
            continuation.resume(throwing: LocationLookupError.unavailable)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(throwing: LocationLookupError.unavailable)
    }
}

@MainActor
final class WeatherQueryService {
    static let shared = WeatherQueryService()

    private let geocoder = CLGeocoder()

    func response(for userQuery: String) async -> String {
        let trimmed = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayOffset = requestedForecastDayOffset(from: trimmed)
        if let explicitLocation = extractLocation(from: trimmed) {
            guard let location = await geocode(address: explicitLocation) else {
                return "I couldn’t find that location. Please try a clearer place name."
            }
            return await weatherSummary(for: location, displayName: explicitLocation, dayOffset: dayOffset)
        }

        do {
            let location = try await UserLocationProvider.shared.currentLocation()
            let displayName = await reverseGeocodedName(for: location) ?? "your current location"
            return await weatherSummary(for: location, displayName: displayName, dayOffset: dayOffset)
        } catch LocationLookupError.denied {
            return "Please enable Location access in Settings so I can use your current location for weather."
        } catch {
            return "I couldn’t get your current location right now. You can ask like: weather in Singapore."
        }
    }

    private func geocode(address: String) async -> CLLocation? {
        await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(address) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location)
            }
        }
    }

    private func reverseGeocodedName(for location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let name = placemarks?.first.flatMap { place in
                    if let locality = place.locality, let country = place.country {
                        return "\(locality), \(country)"
                    }
                    if let name = place.name {
                        return name
                    }
                    return place.locality ?? place.country
                }
                continuation.resume(returning: name)
            }
        }
    }

    private func weatherSummary(for location: CLLocation, displayName: String, dayOffset: Int) async -> String {
        #if canImport(WeatherKit)
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let forecastDays = weather.dailyForecast.forecast

            if dayOffset > 0, let selectedDay = forecastDays[safe: dayOffset] {
                let highC = Int(selectedDay.highTemperature.converted(to: .celsius).value.rounded())
                let lowC = Int(selectedDay.lowTemperature.converted(to: .celsius).value.rounded())
                let condition = String(describing: selectedDay.condition)
                    .replacingOccurrences(of: "_", with: " ")
                    .lowercased()
                return "\(forecastDayLabel(for: dayOffset).capitalized) in \(displayName): \(condition). Range \(lowC)°C to \(highC)°C."
            }

            let current = weather.currentWeather
            let celsius = Int(current.temperature.converted(to: .celsius).value.rounded())
            let fahrenheit = Int(current.temperature.converted(to: .fahrenheit).value.rounded())
            let condition = String(describing: current.condition)
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()

            if let today = forecastDays.first {
                let highC = Int(today.highTemperature.converted(to: .celsius).value.rounded())
                let lowC = Int(today.lowTemperature.converted(to: .celsius).value.rounded())
                return "Weather for \(displayName): \(condition), \(celsius)°C (\(fahrenheit)°F). Today’s range is \(lowC)°C to \(highC)°C."
            }

            return "Weather for \(displayName): \(condition), \(celsius)°C (\(fahrenheit)°F)."
        } catch {
            if let fallback = await fetchFallbackWeather(for: location, displayName: displayName, dayOffset: dayOffset) {
                return fallback
            }
            return "I couldn’t fetch weather from WeatherKit right now (capability/sandbox issue) and fallback weather is unavailable. Please try again."
        }
        #else
        if let fallback = await fetchFallbackWeather(for: location, displayName: displayName, dayOffset: dayOffset) {
            return fallback
        }
        return "Weather forecast is not available on this platform build."
        #endif
    }

    private func fetchFallbackWeather(for location: CLLocation, displayName: String, dayOffset: Int) async -> String? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let endpoint = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,weather_code&timezone=auto"

        guard let url = URL(string: endpoint) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temperatureC = current["temperature_2m"] as? Double,
                  let weatherCode = current["weather_code"] as? Int else {
                return nil
            }

            let temperatureF = Int((temperatureC * 9 / 5 + 32).rounded())
            let roundedC = Int(temperatureC.rounded())
            let condition = weatherCodeDescription(weatherCode)

            if let daily = json["daily"] as? [String: Any],
               let highs = daily["temperature_2m_max"] as? [Double],
               let lows = daily["temperature_2m_min"] as? [Double],
               let dailyCodes = daily["weather_code"] as? [Int],
               let high = highs[safe: dayOffset],
               let low = lows[safe: dayOffset] {
                let dayLabel = forecastDayLabel(for: dayOffset)
                if dayOffset > 0 {
                    let dailyCondition = weatherCodeDescription(dailyCodes[safe: dayOffset] ?? weatherCode)
                    return "\(dayLabel.capitalized) in \(displayName): \(dailyCondition). Range \(Int(low.rounded()))°C to \(Int(high.rounded()))°C."
                }

                return "Weather for \(displayName): \(condition), \(roundedC)°C (\(temperatureF)°F). Today’s range is \(Int(low.rounded()))°C to \(Int(high.rounded()))°C."
            }

            return "Weather for \(displayName): \(condition), \(roundedC)°C (\(temperatureF)°F)."
        } catch {
            return nil
        }
    }

    private func requestedForecastDayOffset(from query: String) -> Int {
        let lower = query.lowercased()
        if lower.contains("day after tomorrow") {
            return 2
        }
        if lower.contains("tomorrow") {
            return 1
        }
        return 0
    }

    private func forecastDayLabel(for dayOffset: Int) -> String {
        switch dayOffset {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2: return "the day after tomorrow"
        default:
            if let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
            return "that day"
        }
    }

    private func weatherCodeDescription(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "current conditions"
        }
    }

    private func extractLocation(from query: String) -> String? {
        let lower = query.lowercased()
        let genericOnly: Set<String> = [
            "weather", "forecast", "weather today", "forecast today", "weather now", "weather currently", "today", "now"
        ]
        if genericOnly.contains(lower.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return nil
        }

        let patterns = [
            "\\b(?:in|at|for)\\s+([a-zA-Z][a-zA-Z\\s,.'-]{1,60})",
            "\\bweather\\s+(?:in\\s+)?([a-zA-Z][a-zA-Z\\s,.'-]{1,60})",
            "\\bforecast\\s+(?:for\\s+|in\\s+)?([a-zA-Z][a-zA-Z\\s,.'-]{1,60})"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(query.startIndex..<query.endIndex, in: query)
            guard let match = regex.firstMatch(in: query, options: [], range: range), match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: query) else { continue }

            var candidate = String(query[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            candidate = candidate.replacingOccurrences(of: "\\b(today|tomorrow|now|currently|right now|this week|tonight)\\b", with: "", options: [.regularExpression, .caseInsensitive])
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - View

struct ContentView: View {
    private let maxChatMessages = 250
    @State private var tasks: [TaskItem] = []
    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var pendingDraft: TaskDraft = .init(title: "")
    @State private var pendingMessage: MessageDraft = .init()
    @State private var pendingEmail: EmailDraft = .init()
    @State private var pendingCallRecipient: String = ""
    @State private var pendingScheduledActionPayload: TaskItem.AgentAction? = nil
    @State private var interactionState: InteractionState = .idle
    @State private var showTaskDetailSheet = false
    @State private var showNotificationAlert = false
    @State private var showCalendarAlert = false
    @State private var lastIntentSource: String = "fallback"
    @State private var lastIntentReason: String = "not-run"
    @State private var showKeySheet = false
    @State private var showSettingsSheet = false
    @State private var showHelpSheet = false
    @State private var showAboutSheet = false
    @State private var showAIUsageSheet = false
    @State private var showTrackingSheet = false
    @State private var showTasksList = false
    @State private var showMessageComposer = false
    @State private var showEmailComposer = false
    #if canImport(UIKit)
    @State private var showCameraCapture = false
    #endif
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif
    @State private var pendingAttachment: PendingAttachment?
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://pa-agent-api-management-service-01.azure-api.net/openai/models/chat/completions?api-version=2024-05-01-preview"
    @AppStorage("AGENT_NAME") private var agentName: String = "Nexa"
    @AppStorage("USER_NAME") private var userName: String = ""
    @AppStorage("AGENT_ICON") private var agentIcon: String = "brain.head.profile"
    @AppStorage("AGENT_ICON_COLOR") private var agentIconColor: String = "purple"
    @AppStorage("USER_ICON") private var userIcon: String = "person.circle.fill"
    @AppStorage("AGENT_VOICE_ENABLED") private var agentVoiceEnabled: Bool = true
    @AppStorage("AGENT_VOICE_IDENTIFIER") private var agentVoiceIdentifier: String = ""
    @AppStorage("PREFERRED_TASK_CALENDAR_ID") private var preferredTaskCalendarId: String = ""
    @AppStorage(CalendarEventStartDateStore.key) private var calendarEventStartTimestamp: Double = CalendarEventStartDateStore.defaultTimestamp
    @StateObject private var historyManager = ActivityHistoryManager()
    @StateObject private var trackingManager = TrackingManager()
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var speechManager = SpeechManager()
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showNotificationList = false
    @State private var showSavedItemsSheet = false
    @State private var selectedTaskForDetail: TaskItem?
    @AppStorage("PERMISSION_SETUP_SHOWN") private var permissionSetupShown: Bool = false
    @State private var showPermissionSetupSheet = false
    @FocusState private var isInputFocused: Bool
    @Namespace private var scrollSpace
    private let eventStore = EKEventStore()
    private let intentAnalyzer = IntentAnalyzer()
    private let intentService = IntentService()
    private let weatherService = WeatherQueryService.shared

    @State private var taskTimer: Timer.TimerPublisher = Timer.publish(every: 60, on: .main, in: .common)
    @State private var timerCancellable: Cancellable?
    @State private var showingAgentTaskAlert = false
    @State private var pendingAgentTask: TaskItem?
    @State private var showingOverdueTaskAlert = false
    @State private var pendingOverdueTask: TaskItem?
    @State private var promptedOverdueTaskIDs: Set<UUID> = []
    @State private var isAgentThinking = false
    @State private var copiedAgentMessageID: UUID?
    @State private var showScheduleConflictAlert = false
    @State private var pendingConflictTask: TaskItem?
    @State private var pendingConflictMatches: [TaskItem] = []
    @State private var savedAgentItems: [SavedAgentItem] = []
    @State private var recentCalendarOccurrenceStatuses: [String: TaskItem.TaskStatus] = [:]
    private let calendarOccurrenceStatusesStoreKey = "calendar_occurrence_statuses_v1"
    private let savedAgentItemsStoreKey = "saved_agent_items_v1"
    
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if permissionSetupShown {
                mainContent
            } else {
                PermissionWelcomeView {
                    showPermissionSetupSheet = true
                }
            }
        }
        .sheet(isPresented: $showPermissionSetupSheet) {
            PermissionSetupSheet(
                allowSkip: permissionSetupShown,
                initialCalendarStartDate: CalendarEventStartDateStore.normalizedDate(from: calendarEventStartTimestamp)
            ) { notifications, speech, calendar, reminders, photos, camera, location, calendarStartDate in
                Task {
                    calendarEventStartTimestamp = CalendarEventStartDateStore
                        .normalizedDate(from: calendarStartDate.timeIntervalSince1970)
                        .timeIntervalSince1970

                    await requestSelectedPermissions(
                        notifications: notifications,
                        speech: speech,
                        calendar: calendar,
                        reminders: reminders,
                        photos: photos,
                        camera: camera,
                        location: location
                    )
                    await refreshSystemTasks()
                    
                    await MainActor.run {
                        permissionSetupShown = true
                        showPermissionSetupSheet = false
                    }
                }
            } onSkip: {
                showPermissionSetupSheet = false
            }
            .interactiveDismissDisabled(!permissionSetupShown)
        }
    }

    private var mainContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                chatArea
                Divider()
                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                setupNotifications()
                setupSpeech()
                #if !DEBUG
                Task { await subscriptionManager.refreshSubscriptionStatus() }
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                checkAgentTasks(at: Date())
                Task { await refreshSystemTasks() }
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                     checkAgentTasks(at: Date())
                     Task { await refreshSystemTasks() }
                } else if newPhase == .inactive || newPhase == .background {
                    ChatHistoryStore.shared.flushMessages(messages)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showTaskDetailSheet) {
                taskDetailSheet
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView(historyManager: historyManager)
            }
            .sheet(isPresented: $showHelpSheet) {
                NavigationStack {
                    HelpView()
                }
            }
            .sheet(isPresented: $showAboutSheet) {
                NavigationStack {
                    AboutView()
                }
            }
            .sheet(isPresented: $showAIUsageSheet) {
                AIUsageView()
            }
            .sheet(isPresented: $showTrackingSheet) {
                TrackingCategoriesView(trackingManager: trackingManager)
            }
            .sheet(isPresented: $showTasksList) {
                TasksListSheet(
                    tasks: $tasks,
                    onTaskChanged: { task in
                        syncTaskStatusToCalendarIfNeeded(task)
                    },
                    onRequestCalendarAccess: {
                        Task {
                            await requestCalendarAccessIfNeeded()
                            await refreshSystemTasks()
                        }
                    },
                    onRequestRemindersAccess: {
                        Task {
                            await requestRemindersAccessIfNeeded()
                            await refreshSystemTasks()
                        }
                    }
                )
            }
            .sheet(isPresented: $showSavedItemsSheet) {
                SavedItemsSheet(items: $savedAgentItems)
            }
            .sheet(item: $selectedTaskForDetail) { task in
                TaskDetailsSheet(task: task)
            }
            .sheet(isPresented: $showMessageComposer) {
                MessageComposerView(recipients: [pendingMessage.recipient], body: pendingMessage.body) { result in
                    if result == .sent {
                        // Mark as done immediately
                        if let t = pendingAgentTask {
                            completeTask(t)
                        } else {
                            recordSentMessageAsTask(recipient: pendingMessage.recipient, body: pendingMessage.body)
                        }
                        messages.append(.init(isUser: false, text: "Message sent and logged."))
                    } else if result == .cancelled {
                        messages.append(.init(isUser: false, text: "Message cancelled."))
                    } else {
                        messages.append(.init(isUser: false, text: "Message failed."))
                    }
                    // Clear pending execution context
                    pendingAgentTask = nil
                    pendingMessage = .init()
                }
            }
            .sheet(isPresented: $showEmailComposer) {
                EmailComposerView(recipient: pendingEmail.recipient, subject: pendingEmail.subject, body: pendingEmail.body) { result, err in
                    if result == .sent {
                        messages.append(.init(isUser: false, text: "Email sent successfully."))
                        historyManager.addLog(actionType: "Email", description: "Sent to \(pendingEmail.recipient)")
                        if let t = pendingAgentTask {
                            completeTask(t)
                        }
                    } else if result == .cancelled {
                         messages.append(.init(isUser: false, text: "Email cancelled."))
                    } else {
                         messages.append(.init(isUser: false, text: "Email failed to send."))
                    }
                    pendingAgentTask = nil
                }
            }
            #if canImport(UIKit)
            .sheet(isPresented: $showCameraCapture) {
                CameraCaptureView { image in
                    Task {
                        await processCapturedImage(image)
                    }
                }
            }
            #endif
            #if canImport(PhotosUI)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await loadPendingAttachment(from: newItem)
                    await MainActor.run {
                        selectedPhotoItem = nil
                    }
                }
            }
            #endif
            // Modified Alert similar to legacy but optimized for agent confirmation
            .alert(isPresented: $showingAgentTaskAlert) {
                let title = pendingAgentTask?.title ?? "Agent Task Ready"
                let action = pendingAgentTask?.actionPayload?.type ?? "action"
                let recipient = pendingAgentTask?.actionPayload?.recipient ?? "someone"
                
                return Alert(
                    title: Text("Task Due: \(title)"),
                    message: Text("It's time to \(action) \(recipient). Proceed now?"),
                    primaryButton: .default(Text("Yes, Proceed")) {
                        if let t = pendingAgentTask { executeAgentTask(t) }
                    },
                    secondaryButton: .cancel(Text("Not Now")) {
                         // Snooze logic or just ignore
                         if let t = pendingAgentTask, let idx = tasks.firstIndex(where: { $0.id == t.id }) {
                            // Snooze for 1 hour
                            tasks[idx].startDate = Date().addingTimeInterval(3600)
                            saveTasks()
                        }
                        pendingAgentTask = nil
                    }
                )
            }
            .alert("Reminder not scheduled", isPresented: $showNotificationAlert, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text("I couldn't schedule a start-date reminder. Check notification permissions.")
            })
            .alert("Task Overdue", isPresented: $showingOverdueTaskAlert, presenting: pendingOverdueTask) { task in
                if canDoTaskNow(task) {
                    Button("Do It Now") {
                        doTaskNow(task)
                        pendingOverdueTask = nil
                    }
                }
                Button("Complete") {
                    completeTask(task)
                    pendingOverdueTask = nil
                }
                Button("Postpone 1 Hour") {
                    postponeTask(task, by: 3600)
                    pendingOverdueTask = nil
                }
                Button("Cancel Task", role: .destructive) {
                    cancelTask(task)
                    pendingOverdueTask = nil
                }
                Button("Close", role: .cancel) {
                    pendingOverdueTask = nil
                }
            } message: { task in
                Text("\(task.title) is overdue. You can complete, postpone, or cancel it.")
            }
            .alert("Calendar access needed", isPresented: $showCalendarAlert, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text("I couldn't add the task to Calendar. Please enable calendar access in Settings.")
            })
            .alert("Schedule conflict", isPresented: $showScheduleConflictAlert, actions: {
                Button("Change Date/Time", role: .cancel) {
                    if let task = pendingConflictTask {
                        pendingDraft = TaskDraft(
                            title: task.title,
                            startDate: task.startDate,
                            dueDate: task.dueDate,
                            priority: task.priority,
                            tag: task.tag
                        )
                        pendingScheduledActionPayload = task.actionPayload
                    }
                    showTaskDetailSheet = true
                    pendingConflictTask = nil
                    pendingConflictMatches = []
                }
                Button("Create Anyway") {
                    if let task = pendingConflictTask {
                        insertTask(task, announce: true)
                        pendingDraft = TaskDraft(title: "")
                        pendingScheduledActionPayload = nil
                        showTaskDetailSheet = false
                    }
                    pendingConflictTask = nil
                    pendingConflictMatches = []
                }
            }, message: {
                Text(scheduleConflictMessage)
            })
            .onAppear {
                loadPersistedCalendarOccurrenceStatuses()
                if userName.isEmpty {
                    Task {
                        // Try to fetch name from contacts or device name
                        if let name = await ContactHelpers().getMeCardName() {
                            userName = name
                        } else {
                            // Fallback to strict device name check
                            let devName = UIDevice.current.name
                            if devName != "iPhone" {
                                userName = devName
                            }
                        }
                    }
                }

                let persistedMessages = ChatHistoryStore.shared.loadMessages()
                if !persistedMessages.isEmpty {
                    messages = persistedMessages
                }

                if messages.isEmpty {
                    let displayUser = userName.isEmpty ? "You" : userName
                    messages.append(.init(isUser: false, text: "Hi \(displayUser)! I’m \(agentName). Tell me what you need and I’ll track and prioritize tasks for you."))
                }
                loadSavedAgentItems()
                loadTasks()
                Task { await refreshSystemTasks() }
                // Start timer
                timerCancellable = taskTimer.connect()
            }
            .onDisappear {
                ChatHistoryStore.shared.flushMessages(messages)
                timerCancellable?.cancel()
                timerCancellable = nil
                speechManager.stopRecording()
                speechManager.onSilence = nil
            }
            .onReceive(taskTimer) { time in
                checkAgentTasks(at: time)
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatHistoryDidImport)) { _ in
                messages = ChatHistoryStore.shared.loadMessages()
            }
            .onChange(of: tasks) { _, _ in saveTasks() }
            .onChange(of: savedAgentItems) { _, _ in saveSavedAgentItems() }
            .onChange(of: calendarEventStartTimestamp) { _, _ in
                Task { await refreshSystemTasks() }
            }
            .onTapGesture {
                dismissKeyboard()
            }
        }
    }

    private func checkAgentTasks(at time: Date) {
        // Prevent interruption if already handling tasks
        guard !showMessageComposer, !showEmailComposer, !showingAgentTaskAlert, !showingOverdueTaskAlert else { return }

        if let overdueTask = tasks.first(where: { $0.isOverdue(now: time) && !promptedOverdueTaskIDs.contains($0.id) }) {
            pendingOverdueTask = overdueTask
            promptedOverdueTaskIDs.insert(overdueTask.id)
            showingOverdueTaskAlert = true
            return
        }

        let overdue = tasks.filter { 
            !$0.isDone && 
            $0.executor == .agent && 
            $0.startDate <= time 
        }
        
        if let first = overdue.first {
            pendingAgentTask = first
            // Unlike before, we do NOT auto-execute. We show an alert to confirm.
            showingAgentTaskAlert = true
        }
    }
    
    private func executeAgentTask(_ task: TaskItem) {
        guard let payload = task.actionPayload else { return }
        
        // Just-in-Time Resolution and Generation
        Task {
            // 1. Resolve Recipient (if not already a number/email)
            var finalRecipient = payload.recipient
            // Check if it's a raw name (no digits, no @)
            let isRawName = finalRecipient.rangeOfCharacter(from: .decimalDigits) == nil && !finalRecipient.contains("@")
            
            if isRawName {
                 // Try to resolve using fuzzy matching
                 let candidates = await ContactHelpers().find(name: finalRecipient)
                 // Prefer mobile/phone for SMS/Call
                 var found = false
                 if payload.type.contains("Call") || payload.type.contains("Message") || payload.type.contains("call") {
                     if let best = candidates.first(where: { !$0.number.isEmpty }) {
                         finalRecipient = best.number
                         found = true
                     }
                 } else if payload.type.contains("Email") || payload.type.contains("email") {
                     if let best = candidates.first(where: { $0.email?.isEmpty == false }) {
                         finalRecipient = best.email!
                         found = true
                     }
                 }
                 
                 // If not found valid candidate
                 if !found {
                      await MainActor.run {
                          let type = (payload.type.contains("Email") || payload.type.contains("email")) ? "email" : "phone"
                          interactionState = .resolvingMissingTaskContact(task: task, missingType: type)
                          withAnimation {
                              messages.append(.init(isUser: false, text: "I couldn't find a \(type == "phone" ? "phone number" : "email address") for '\(finalRecipient)'. Do you want to add a new contact?"))
                          }
                      }
                      return
                 }
            } else {
                 // Even if not raw name, validate format
                 let type = (payload.type.contains("Email") || payload.type.contains("email")) ? "email" : "phone"
                 var valid = true
                 if type == "email" && !finalRecipient.contains("@") { valid = false }
                 if type == "phone" {
                     let digits = finalRecipient.filter { "0123456789".contains($0) }
                     if digits.count < 3 { valid = false }
                 }
                 
                 if !valid {
                      await MainActor.run {
                          interactionState = .resolvingMissingTaskContact(task: task, missingType: type)
                          withAnimation {
                              messages.append(.init(isUser: false, text: "The stored \(type) info '\(finalRecipient)' seems invalid. Do you want to add a new contact or update it?"))
                          }
                      }
                      return
                 }
            }
            
            // 2. Generate Content (if body exists but we want fresh AI generation)
            // The stored 'body' is treated as the prompt/instruction.
            // "Ask Ivy about dinner" -> AI -> "Hey Ivy, are we still on for dinner?"
            var finalBody = payload.body ?? ""
            
            // Only generate if it looks like an instruction (heuristic) or just always polish?
            // The user requested "use ai to extract... and populate".
            // Let's perform a quick polish/generation pass at runtime.
            // We use the same 'polishMessage' function.
            let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
            let signatureName = userName.isEmpty ? "The User" : userName
            
            if payload.type == "sendMessage" || payload.type == "sendEmail" {
                await MainActor.run {
                     withAnimation { messages.append(.init(isUser: false, text: "drafting content for \(finalRecipient)...")) }
                }
                
                // We pass the stored body as 'text'
                if isAIFeatureEnabled,
                   let generated = await intentService.polishMessage(text: finalBody, history: "", recipient: finalRecipient, senderName: signatureName, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, agentName: agentName) {
                    finalBody = generated
                }
                
                // Add signature
                let signature = "\n\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)"
                if !finalBody.contains("AI powered personal assistant") {
                    finalBody += signature
                }
            }

            await MainActor.run {
                if payload.type == "sendMessage" {
                    if finalBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pendingMessage = MessageDraft(recipient: finalRecipient, body: "")
                        interactionState = .collectingMessageBody
                        withAnimation {
                            messages.append(.init(isUser: false, text: "What should I message \(finalRecipient)?"))
                        }
                        return
                    }
                    pendingMessage = MessageDraft(recipient: finalRecipient, body: finalBody)
                    showMessageComposer = true
                } else if payload.type == "sendEmail" {
                    if finalBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pendingEmail = EmailDraft(recipient: finalRecipient, subject: payload.subject ?? "Update", body: "")
                        interactionState = .collectingEmailBody
                        withAnimation {
                            messages.append(.init(isUser: false, text: "What should the email to \(finalRecipient) say?"))
                        }
                        return
                    }
                    // For email, we might want to generate a subject too if missing? 
                    // PolishMessage returns just body. 
                    // Let's keep subject as is for now.
                    pendingEmail = EmailDraft(recipient: finalRecipient, subject: payload.subject ?? "Update", body: finalBody)
                    showEmailComposer = true
                } else if payload.type == "makePhoneCall" || payload.type == "call" {
                    if let script = payload.script, !script.isEmpty {
                        let instruction = "Connecting you to \(finalRecipient). You should say: \(script)"
                        if agentVoiceEnabled {
                            speechManager.speak(instruction, voiceIdentifier: agentVoiceIdentifier)
                        }
                        messages.append(.init(isUser: false, text: "Script: \(script)"))
                    }
                    Task { await triggerCall(to: finalRecipient) }
                    completeTask(task)
                }
            }
        }
    }
    
    private func completeTask(_ task: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].markCompleted()
            syncTaskStatusToCalendarIfNeeded(tasks[idx])
            promptedOverdueTaskIDs.remove(task.id)
            historyManager.addLog(actionType: "Task", description: "Completed: \(tasks[idx].title)")
            reprioritize()
        }
    }

    private func cancelTask(_ task: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].markCanceled()
            syncTaskStatusToCalendarIfNeeded(tasks[idx])
            promptedOverdueTaskIDs.remove(task.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
            historyManager.addLog(actionType: "Task", description: "Canceled: \(tasks[idx].title)")
            messages.append(.init(isUser: false, text: "Canceled task: \(tasks[idx].title)"))
            reprioritize()
        }
    }

    private func postponeTask(_ task: TaskItem, by interval: TimeInterval) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].markOpen()
            tasks[idx].startDate = Date().addingTimeInterval(interval)
            tasks[idx].dueDate = tasks[idx].dueDate.addingTimeInterval(interval)
            syncTaskStatusToCalendarIfNeeded(tasks[idx])
            promptedOverdueTaskIDs.remove(task.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
            scheduleReminder(for: tasks[idx])
            historyManager.addLog(actionType: "Task", description: "Postponed: \(tasks[idx].title) by 1 hour")
            messages.append(.init(isUser: false, text: "Postponed task by 1 hour: \(tasks[idx].title)"))
            reprioritize()
        }
    }

    private func canDoTaskNow(_ task: TaskItem) -> Bool {
        guard let type = task.actionPayload?.type.lowercased() else { return false }
        return type == "sendmessage" || type == "sendemail" || type == "makephonecall" || type == "call"
    }

    private func doTaskNow(_ task: TaskItem) {
        guard canDoTaskNow(task) else {
            messages.append(.init(isUser: false, text: "This overdue task does not have a direct SMS/email/call action to run now."))
            return
        }

        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].markOpen()
            promptedOverdueTaskIDs.remove(task.id)
            pendingAgentTask = tasks[idx]
            executeAgentTask(tasks[idx])
        } else {
            pendingAgentTask = task
            executeAgentTask(task)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(agentName)
                    .font(.title.bold())
                Text("Speak tasks, capture details, and keep priorities tight.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(action: { showTasksList = true }) {
                Image(systemName: "checklist")
                    .font(.title3)
            }
            .padding(.trailing, 8)

            Button(action: { showSavedItemsSheet = true }) {
                Image(systemName: "bookmark")
                    .font(.title3)
            }
            .padding(.trailing, 8)
            .accessibilityLabel("Saved items")

            Button(action: startNewChatSession) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
            }
            .padding(.trailing, 8)
            .accessibilityLabel("New chat")
            
            Menu {
                Button(action: { showNotificationList = true }) {
                    Label("Notifications", systemImage: "bell")
                }
                Button(action: { showTrackingSheet = true }) {
                    Label("Tracking", systemImage: "list.clipboard")
                }
                Button(action: { showAIUsageSheet = true }) {
                    Label("AI usage", systemImage: "chart.bar")
                }
                Button(action: { showSettingsSheet = true }) {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(action: { showHelpSheet = true }) {
                    Label("Help", systemImage: "questionmark.circle")
                }
                Divider()
                Button(action: { showAboutSheet = true }) {
                    Label("About Us", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .sheet(isPresented: $showNotificationList) {
            NotificationListView(manager: notificationManager)
        }
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

                    if case .clarifyingContact(let candidates, _, _) = interactionState {
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
                    
                    // Interaction Buttons for Email Flows
                    if case .verifyingEmailContact = interactionState {
                        HStack(spacing: 20) {
                            Button("Yes") {
                                Task { await handleIntent(for: "Yes") }
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("No") {
                                Task { await handleIntent(for: "No") }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                    }
                    
                    if case .offeringToSaveEmail = interactionState {
                        HStack(spacing: 20) {
                            Button("Save") {
                                Task { await handleIntent(for: "Yes") }
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("Don't Save") {
                                Task { await handleIntent(for: "No") }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                    }

                    if case .confirmingTaskConflict(_, _, _, let suggestions) = interactionState {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose a time option:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                                Button {
                                    Task { await handleIntent(for: "\(index + 1)") }
                                } label: {
                                    HStack {
                                        Text("\(index + 1). \(suggestion.formatted(date: .abbreviated, time: .shortened))")
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                                }
                            }

                            Button("Go ahead with current time") {
                                Task { await handleIntent(for: "go ahead") }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if isAgentThinking {
                        thinkingIndicator
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    
                    // Invisible footer to scroll to
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .onChange(of: messages) { oldValue, newValue in
                    if newValue.count > maxChatMessages {
                        messages = Array(newValue.suffix(maxChatMessages))
                        return
                    }

                    ChatHistoryStore.shared.saveMessages(newValue)

                    // Scroll to bottom whenever messages change
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    
                    // Auto-speak new agent messages
                    if newValue.count > oldValue.count,
                       let lastMsg = newValue.last,
                       !lastMsg.isUser {
                        if agentVoiceEnabled {
                            speechManager.speak(lastMsg.text, voiceIdentifier: agentVoiceIdentifier)
                        }
                    }
                }
                .onChange(of: interactionState) { _, _ in
                    // Scroll to bottom whenever interaction state changes (buttons appear/disappear)
                    // Add a slight delay to allow layout to update
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: draft) { _, _ in
                    // Optional: Scroll to bottom while typing if needed, mostly for multiline
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                dismissKeyboard()
            }
        }
    }

    private func messageBubble(for message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser {
                Spacer()
            } else {
                Image(systemName: agentIcon)
                    .font(.title2)
                    .foregroundStyle(agentAccentColor)
                    .frame(width: 32, height: 32)
                    .background(agentAccentColor.opacity(0.12))
                    .clipShape(Circle())
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if !message.isUser {
                    Text(agentName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 10) {
                    if !message.isUser,
                       let responseTitle = message.responseTitle,
                       !responseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(responseTitle)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }

                    Text(message.text)
                        .foregroundStyle(.primary)

                    if let snapshot = message.taskStatusSnapshot {
                        taskStatusChart(snapshot)
                    }

                    if message.isUser {
                        Text(message.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text(message.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button {
                                toggleSavedAgentResponse(message)
                            } label: {
                                Image(systemName: isSavedAgentResponse(message) ? "bookmark.fill" : "bookmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isSavedAgentResponse(message) ? "Remove from saved items" : "Save response")
                            Button {
                                copyAgentResponse(message)
                            } label: {
                                Image(systemName: copiedAgentMessageID == message.id ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy response")
                        }
                    }
                }
                .padding()
                .background(message.isUser ? Color.accentColor.opacity(0.15) : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05))
                )
            }

            if message.isUser {
                Image(systemName: userIcon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Circle())
            } else {
                Spacer()
            }
        }
        .transition(.move(edge: message.isUser ? .trailing : .leading).combined(with: .opacity))
    }

    private func taskStatusChart(_ snapshot: TaskStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Task Status")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if canImport(Charts)
            let rows: [StatusCategoryRow] = [
                .init(status: "Completed", category: "Work", count: snapshot.completedWork),
                .init(status: "Completed", category: "Personal", count: snapshot.completedPersonal),
                .init(status: "Completed", category: "Other", count: snapshot.completedOther),
                .init(status: "Overdue", category: "Work", count: snapshot.overdueWork),
                .init(status: "Overdue", category: "Personal", count: snapshot.overduePersonal),
                .init(status: "Overdue", category: "Other", count: snapshot.overdueOther),
                .init(status: "Upcoming", category: "Work", count: snapshot.upcomingWork),
                .init(status: "Upcoming", category: "Personal", count: snapshot.upcomingPersonal),
                .init(status: "Upcoming", category: "Other", count: snapshot.upcomingOther)
            ]
            .filter { $0.count > 0 }

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
            .frame(height: 130)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            #else
            Text("Completed W/P/O: \(snapshot.completedWork)/\(snapshot.completedPersonal)/\(snapshot.completedOther) • Overdue W/P/O: \(snapshot.overdueWork)/\(snapshot.overduePersonal)/\(snapshot.overdueOther) • Upcoming W/P/O: \(snapshot.upcomingWork)/\(snapshot.upcomingPersonal)/\(snapshot.upcomingOther)")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var thinkingIndicator: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: agentIcon)
                .font(.title2)
                .foregroundStyle(agentAccentColor)
                .frame(width: 32, height: 32)
                .background(agentAccentColor.opacity(0.12))
                .clipShape(Circle())

            HStack(spacing: 8) {
                ThinkingDotsView()
                Text("\(agentName) is thinking…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05))
            )

            Spacer()
        }
    }

    private struct ThinkingDotsView: View {
        @State private var animate = false

        var body: some View {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(animate ? 0.6 : 1.0)
                        .opacity(animate ? 0.35 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                            value: animate
                        )
                }
            }
            .onAppear {
                animate = true
            }
        }
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

            HStack(spacing: 12) {
                Label("Work", systemImage: "briefcase.fill")
                Label("Personal", systemImage: "person.fill")
                Label("Other", systemImage: "questionmark.circle.fill")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(visibleTasks) { task in
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
                Text(task.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(for: task).opacity(0.18))
                    .foregroundStyle(statusColor(for: task))
                    .clipShape(Capsule())
                Spacer()
                if task.executor == .agent {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                         .foregroundStyle(agentAccentColor)
                         .help("\(agentName) Task")
                }
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
                Image(systemName: task.categoryIconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(task.categoryLabel)
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(task.dueDate, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(
                task.status == .completed || task.isDone
                    ? "Completed: \((task.completedAt ?? task.startDate).formatted(date: .abbreviated, time: .omitted))"
                    : "Start: \(task.startDate.formatted(date: .abbreviated, time: .omitted))"
            )
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(taskBackgroundColor(task))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTaskForDetail = task
        }
    }

    private var visibleTasks: [TaskItem] {
        tasks.filter { !$0.isStaleOverdue() }
    }

}

// MARK: - Task List Sheet (Moved to top-level)

struct TasksListSheet: View {
    @Binding var tasks: [TaskItem]
    @AppStorage("PREFERRED_TASK_CALENDAR_ID") private var preferredTaskCalendarId: String = ""
    var onTaskChanged: (TaskItem) -> Void = { _ in }
    var onRequestCalendarAccess: () -> Void = {}
    var onRequestRemindersAccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: TaskFilter = .today
    @State private var selectedStatusFilter: StatusFilter = .open
    @State private var selectedTaskForDetail: TaskItem?
    @State private var selectedCalendarName: String = "Default"
    private let eventStore = EKEventStore()

    enum TaskFilter: String, CaseIterable {
        case all = "All"
        case today = "Today"
        case upcoming = "Upcoming"
    }

    enum StatusFilter: String, CaseIterable {
        case all = "All"
        case open = "Open"
        case completed = "Completed"
        case canceled = "Canceled"
    }

    var filteredTasks: [TaskItem] {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: todayStart)!
        let visibleTasks = tasks.filter { !$0.isStaleOverdue(now: now) }

        return visibleTasks.filter { task in
            let statusMatches: Bool
            switch selectedStatusFilter {
            case .all:
                statusMatches = true
            case .open:
                statusMatches = task.status == .open && !task.isDone
            case .completed:
                statusMatches = task.status == .completed || task.isDone
            case .canceled:
                statusMatches = task.status == .canceled
            }

            guard statusMatches else { return false }

            let targetDate = task.startDate
            switch selectedFilter {
            case .all:
                return true
            case .today:
                if task.status == .open, !task.isDone, task.dueDate < now {
                    return true
                }

                if task.status == .completed || task.isDone {
                    if let completedAt = task.completedAt {
                        return calendar.isDate(completedAt, inSameDayAs: now)
                    }
                    return calendar.isDate(targetDate, inSameDayAs: now)
                }

                return targetDate >= todayStart && targetDate < tomorrowStart
            case .upcoming:
                return targetDate >= tomorrowStart && targetDate < nextWeekStart
            }
        }
        .sorted {
            let lhsRank = statusSortRank(for: $0)
            let rhsRank = statusSortRank(for: $1)

            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
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
                                withAnimation { tasks[index].toggleDoneState() }
                                onTaskChanged(tasks[index])
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
                            Text(task.statusLabel)
                                .font(.caption2)
                                .foregroundStyle(statusColor(for: task))
                            Text(
                                task.status == .completed || task.isDone
                                    ? "Completed: \((task.completedAt ?? task.startDate).formatted(date: .abbreviated, time: .shortened))"
                                    : "\(task.type == .calendar ? "📅 " : "")Start: \(task.startDate.formatted(date: .abbreviated, time: .shortened))"
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Text(task.priorityLabel)
                                .font(.caption2)
                                .padding(4)
                                .background(priorityColor(task.priority).opacity(0.2))
                                .foregroundStyle(priorityColor(task.priority))
                                .cornerRadius(4)
                            Image(systemName: task.categoryIconName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(task.categoryLabel)
                        }

                        Button {
                            selectedTaskForDetail = task
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        if task.status != .canceled {
                            Button("Cancel") {
                                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                                    withAnimation { tasks[index].markCanceled() }
                                    onTaskChanged(tasks[index])
                                }
                            }
                            .tint(.yellow)
                        }

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
                                withAnimation { tasks[index].toggleDoneState() }
                                onTaskChanged(tasks[index])
                            }
                        }
                        .tint(.green)
                    }
                    .listRowBackground(
                        taskRowBackgroundColor(task)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedTaskForDetail = task
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Tasks")
                            .font(.headline)
                        Text("Calendar - \(selectedCalendarName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Enable Calendar Access") { onRequestCalendarAccess() }
                        Button("Enable Reminders Access") { onRequestRemindersAccess() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        printFilteredTaskList()
                    } label: {
                        Image(systemName: "printer")
                    }
                    .accessibilityLabel("Print Task List")
                }
            }
            .onAppear {
                refreshSelectedCalendarName()
            }
            .onChange(of: preferredTaskCalendarId) { _, _ in
                refreshSelectedCalendarName()
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Picker("Status Filter", selection: $selectedStatusFilter) {
                        ForEach(StatusFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Date Filter", selection: $selectedFilter) {
                        ForEach(TaskFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Text("Total Tasks: \(tasks.filter { !$0.isStaleOverdue() }.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial)
            }
            .overlay {
                if filteredTasks.isEmpty {
                    ContentUnavailableView(
                        "No \(selectedStatusFilter.rawValue.lowercased()) tasks for \(selectedFilter.rawValue.lowercased())",
                        systemImage: "checklist",
                        description: Text("Use the top-left menu to enable Calendar and Reminders access, or add tasks by chatting with the agent.")
                    )
                }
            }
            .sheet(item: $selectedTaskForDetail) { task in
                TaskDetailsSheet(task: task)
            }
        }
    }

    private func refreshSelectedCalendarName() {
        if preferredTaskCalendarId.isEmpty {
            selectedCalendarName = "Default"
            return
        }

        let calendars = eventStore.calendars(for: .event)
        if let matched = calendars.first(where: { $0.calendarIdentifier == preferredTaskCalendarId }) {
            selectedCalendarName = matched.title
        } else {
            selectedCalendarName = "Default"
        }
    }

    private func statusSortRank(for task: TaskItem) -> Int {
        if task.status == .canceled {
            return 2
        }
        if task.status == .completed || task.isDone {
            return 1
        }
        return 0
    }

    private func printFilteredTaskList() {
#if canImport(UIKit)
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo.printInfo()
        printInfo.outputType = .general
        printInfo.jobName = "Task List"
        printController.printInfo = printInfo
        printController.printFormatter = UISimpleTextPrintFormatter(text: taskListPrintText())
        printController.present(animated: true)
#endif
    }

    private func taskListPrintText() -> String {
        var lines: [String] = [
            "Task List",
            "Status: \(selectedStatusFilter.rawValue)",
            "Date Filter: \(selectedFilter.rawValue)",
            "Generated: \(Date().formatted(date: .abbreviated, time: .shortened))",
            ""
        ]

        if filteredTasks.isEmpty {
            lines.append("No tasks found.")
            return lines.joined(separator: "\n")
        }

        for (index, task) in filteredTasks.enumerated() {
            lines.append("\(index + 1). \(task.title)")
            lines.append("   Status: \(task.statusLabel)")
            lines.append("   Priority: \(task.priorityLabel)")
            lines.append("   Start: \(task.startDate.formatted(date: .abbreviated, time: .shortened))")
            lines.append("   Due: \(task.dueDate.formatted(date: .abbreviated, time: .shortened))")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
    
    private func priorityColor(_ value: Int) -> Color {
        switch value {
        case 1: return .red
        case 2: return .orange
        default: return .blue
        }
    }

    private func statusColor(for task: TaskItem) -> Color {
        if task.isOverdue() {
            return .orange
        }
        switch task.status {
        case .open: return .secondary
        case .completed: return .green
        case .canceled: return .red
        }
    }

    private func taskRowBackgroundColor(_ task: TaskItem) -> Color {
        if task.isOverdue() {
            return Color.red.opacity(0.18)
        }
        switch task.status {
        case .completed:
            return Color.green.opacity(0.18)
        case .canceled:
            return Color.yellow.opacity(0.22)
        case .open:
            return Color.white
        }
    }
}

struct TaskDetailsSheet: View {
    let task: TaskItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    LabeledContent("Title", value: task.title)
                    LabeledContent("Status", value: task.statusLabel)
                    LabeledContent("Priority", value: task.priorityLabel)
                    LabeledContent("Task Type") {
                        Image(systemName: task.categoryIconName)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(task.categoryLabel)
                    }
                    LabeledContent("Tag", value: task.tag)
                }

                Section("Schedule") {
                    LabeledContent("Start", value: task.startDate.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Due", value: task.dueDate.formatted(date: .abbreviated, time: .shortened))
                }

                Section("Source") {
                    LabeledContent("Type", value: sourceLabel)
                    if let externalId = task.externalId, !externalId.isEmpty {
                        LabeledContent("Calendar ID", value: externalId)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Task Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var sourceLabel: String {
        switch task.type {
        case .app: return "App"
        case .calendar: return "Calendar"
        case .reminder: return "Reminder"
        }
    }
}

struct SavedItemsSheet: View {
    @Binding var items: [SavedAgentItem]
    @Environment(\.openURL) private var openURL
    @State private var editingItem: SavedAgentItem?
    @State private var emailingItem: SavedAgentItem?

    private var sortedItems: [SavedAgentItem] {
        items.sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if sortedItems.isEmpty {
                    ContentUnavailableView(
                        "No saved items",
                        systemImage: "bookmark",
                        description: Text("Favorite an agent response to save it here.")
                    )
                } else {
                    ForEach(sortedItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Saved \(item.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: 12) {
                                Button {
                                    sendSavedItemViaEmail(item)
                                } label: {
                                    Image(systemName: "envelope")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Send via email")

                                ShareLink(item: item.shareText) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    printSavedItem(item)
                                } label: {
                                    Image(systemName: "printer")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Print favorite item")
                            }
                            .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                editingItem = item
                            } label: {
                                Label("View", systemImage: "eye")
                            }
                            .tint(.indigo)

                            Button(role: .destructive) {
                                deleteItem(id: item.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved Items")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingItem) { selectedItem in
                if let itemBinding = bindingForItem(id: selectedItem.id) {
                    NavigationStack {
                        SavedItemDetailView(item: itemBinding)
                    }
                } else {
                    ContentUnavailableView("Item unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .sheet(item: $emailingItem) { selectedItem in
                EmailComposerView(recipient: "", subject: selectedItem.title, body: selectedItem.shareText) { _, _ in
                    emailingItem = nil
                }
            }
        }
    }

    private func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    private func bindingForItem(id: UUID) -> Binding<SavedAgentItem>? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return $items[index]
    }

    private func printSavedItem(_ item: SavedAgentItem) {
        #if canImport(UIKit)
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo.printInfo()
        printInfo.outputType = .general
        printInfo.jobName = item.title
        printController.printInfo = printInfo
        printController.printFormatter = UISimpleTextPrintFormatter(text: item.shareText)
        printController.present(animated: true)
        #endif
    }

    private func sendSavedItemViaEmail(_ item: SavedAgentItem) {
        #if canImport(MessageUI)
        if MFMailComposeViewController.canSendMail() {
            emailingItem = item
            return
        }
        #endif
        sendViaMailto(item)
    }

    private func sendViaMailto(_ item: SavedAgentItem) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: item.title),
            URLQueryItem(name: "body", value: item.shareText)
        ]
        if let url = components.url {
            openURL(url)
        }
    }
}

struct SavedItemDetailView: View {
    @Binding var item: SavedAgentItem
    var startsInEditMode: Bool = false
    @State private var isEditing = false
    @State private var draftTitle: String = ""
    @State private var draftContent: String = ""
    @State private var initialEditModeApplied = false

    var body: some View {
        Group {
            if isEditing {
                Form {
                    Section("Title") {
                        TextField("Title", text: $draftTitle)
                    }

                    Section("Content") {
                        TextEditor(text: $draftContent)
                            .frame(minHeight: 220)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Favorite Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        cancelEditing()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveEdits()
                    }
                    .disabled(draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginEditing()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit favorite item")
                }
            }
        }
        .onAppear {
            syncDraftFromItem()
            if startsInEditMode && !initialEditModeApplied {
                isEditing = true
                initialEditModeApplied = true
            }
        }
    }

    private func beginEditing() {
        syncDraftFromItem()
        isEditing = true
    }

    private func cancelEditing() {
        syncDraftFromItem()
        isEditing = false
    }

    private func saveEdits() {
        let cleanedContent = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedContent.isEmpty else { return }

        let cleanedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        item.content = cleanedContent
        item.title = cleanedTitle.isEmpty ? SavedAgentItem.titleFrom(content: cleanedContent) : String(cleanedTitle.prefix(70))
        isEditing = false
    }

    private func syncDraftFromItem() {
        draftTitle = item.title
        draftContent = item.content
    }
}

struct PermissionWelcomeView: View {
    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Spacer()

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set Up Nexa")
                            .font(.largeTitle.bold())

                        Text("This is the first step to set up Nexa. Please grant the required permissions so Nexa can be fully functional for tasks, reminders, speech, notifications, photos, camera, and location-based weather.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: onStart) {
                    Text("Start Permission Setup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PermissionSetupSheet: View {
    var allowSkip: Bool = true
    var initialCalendarStartDate: Date = CalendarEventStartDateStore.defaultDate
    let onContinue: (_ notifications: Bool, _ speech: Bool, _ calendar: Bool, _ reminders: Bool, _ photos: Bool, _ camera: Bool, _ location: Bool, _ calendarStartDate: Date) -> Void
    let onSkip: () -> Void

    @State private var askNotifications = true
    @State private var askSpeech = true
    @State private var askCalendar = true
    @State private var askReminders = true
    @State private var askPhotos = true
    @State private var askCamera = true
    @State private var askLocation = true
    @State private var calendarStartDate = CalendarEventStartDateStore.defaultDate
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose what to enable. iOS will still show one system prompt per permission type, but this setup lets users control everything from one place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Calendar Event Start Date") {
                    DatePicker("Start Date", selection: $calendarStartDate, displayedComponents: .date)
                    Text("This date controls which calendar events are loaded. Events before this date are ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    Toggle("Notifications", isOn: $askNotifications)
                    Toggle("Speech + Microphone", isOn: $askSpeech)
                    Toggle("Calendar", isOn: $askCalendar)
                    Toggle("Reminders", isOn: $askReminders)
                    Toggle("Photos", isOn: $askPhotos)
                    Toggle("Camera", isOn: $askCamera)
                    Toggle("Location", isOn: $askLocation)
                }
            }
            .navigationTitle("Permission Setup")
            .disabled(isProcessing)
            .toolbar {
                if allowSkip {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") { onSkip() }
                            .disabled(isProcessing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isProcessing ? "Setting up..." : "Continue") {
                        isProcessing = true
                        onContinue(
                            askNotifications,
                            askSpeech,
                            askCalendar,
                            askReminders,
                            askPhotos,
                            askCamera,
                            askLocation,
                            calendarStartDate
                        )
                    }
                    .disabled(isProcessing)
                }
            }
            .onAppear {
                calendarStartDate = Calendar.current.startOfDay(for: initialCalendarStartDate)
            }
        }
    }
}

struct AIUsageView: View {
    private enum ReportRange: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case monthly = "Monthly"

        var id: String { rawValue }
    }

    @StateObject private var tokenUsageManager = TokenUsageManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var reportRange: ReportRange = .daily

    var body: some View {
        NavigationStack {
            List {
                Section("AI Tokens (Today)") {
                    let today = tokenUsageManager.summary(for: Date())
                    let month = tokenUsageManager.monthlySummary(for: Date())
                    let limit = tokenUsageManager.monthlyTokenLimit(hasActiveSubscription: subscriptionManager.hasActiveSubscription)
                    let remaining = tokenUsageManager.remainingTokensThisMonth(hasActiveSubscription: subscriptionManager.hasActiveSubscription)

                    HStack {
                        Text("Requests")
                        Spacer()
                        Text("\(today.requestCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Prompt Tokens")
                        Spacer()
                        Text("\(today.promptTokens)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Completion Tokens")
                        Spacer()
                        Text("\(today.completionTokens)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Total Tokens")
                        Spacer()
                        Text("\(today.totalTokens)")
                            .fontWeight(.semibold)
                    }

                    HStack {
                        Text("Monthly Limit")
                        Spacer()
                        Text("\(limit)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Used This Month")
                        Spacer()
                        Text("\(month.totalTokens)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Remaining This Month")
                        Spacer()
                        Text("\(remaining)")
                            .foregroundStyle(remaining > 0 ? Color.secondary : Color.orange)
                    }
                }

                Section {
                    Picker("View", selection: $reportRange) {
                        ForEach(ReportRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)

                    let dailyRows = tokenUsageManager.dailySummaries(limit: 14)
                    let monthlyRows = tokenUsageManager.monthlySummaries(limit: 12)

                    if reportRange == .daily && dailyRows.isEmpty {
                        Text("No AI token usage yet.")
                            .foregroundStyle(.secondary)
                    } else if reportRange == .monthly && monthlyRows.isEmpty {
                        Text("No AI token usage yet.")
                            .foregroundStyle(.secondary)
                    } else if reportRange == .daily {
                        #if canImport(Charts)
                        let chartRows = dailyRows.sorted { $0.dayStart < $1.dayStart }
                        Chart(chartRows) { day in
                            BarMark(
                                x: .value("Day", day.dayStart, unit: .day),
                                y: .value("Tokens", day.totalTokens)
                            )
                            .foregroundStyle(.blue)
                        }
                        .frame(height: 180)
                        .chartYAxis {
                            AxisMarks(position: .leading)
                        }
                        #endif

                        ForEach(dailyRows) { day in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(day.dayStart.formatted(date: .abbreviated, time: .omitted))
                                        .font(.subheadline)
                                    Text("Requests: \(day.requestCount) • Success: \(day.successfulRequestCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(day.totalTokens)")
                                    .font(.headline)
                            }
                        }
                    } else {
                        #if canImport(Charts)
                        let chartRows = monthlyRows.sorted { $0.monthStart < $1.monthStart }
                        Chart(chartRows) { month in
                            BarMark(
                                x: .value("Month", month.monthStart, unit: .month),
                                y: .value("Tokens", month.totalTokens)
                            )
                            .foregroundStyle(.blue)
                        }
                        .frame(height: 180)
                        .chartYAxis {
                            AxisMarks(position: .leading)
                        }
                        #endif

                        ForEach(monthlyRows) { month in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(month.monthStart.formatted(.dateTime.year().month(.abbreviated)))
                                        .font(.subheadline)
                                    Text("Requests: \(month.requestCount) • Success: \(month.successfulRequestCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(month.totalTokens)")
                                    .font(.headline)
                            }
                        }
                    }
                } header: {
                    Text(reportRange == .daily ? "Daily Usage Report" : "Monthly Usage Report")
                }
            }
            .navigationTitle("AI Usage")
        }
    }
}

extension ContentView {
    // MARK: Input bar

    private var shouldShowCancelConversationPrompt: Bool {
        switch interactionState {
        case .collectingMessageRecipient,
             .collectingCallRecipient,
             .collectingEmailRecipient,
             .clarifyingContact,
             .verifyingEmailContact,
             .collectingEmailAddressForContact,
             .offeringToSaveEmail,
             .resolvingMissingTaskContact,
             .collectingNewContactDetail,
             .collectingScheduledTaskContact:
            return true
        default:
            return false
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            Divider()

            if shouldShowCancelConversationPrompt {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cancel current conversation")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Stops the current contact/chat flow and resets it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button("Cancel") {
                        cancelConversation()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
                .padding(.horizontal)
            }

            if let attachment = pendingAttachment {
                HStack(spacing: 10) {
                    #if canImport(UIKit)
                    if let previewData = attachment.thumbnailJPEGData,
                       let previewImage = UIImage(data: previewData) {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "photo.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    #elseif canImport(AppKit)
                    if let previewData = attachment.thumbnailJPEGData,
                       let previewImage = NSImage(data: previewData) {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "photo.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    #else
                    Image(systemName: "photo.fill")
                        .foregroundStyle(Color.accentColor)
                    #endif

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.caption)
                            .lineLimit(1)
                        Text(attachment.imageResolutionLabel.map { "\($0) • \(attachment.fileSizeLabel)" } ?? attachment.fileSizeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        pendingAttachment = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attachment")
                }
                .padding(.horizontal)
            }

            HStack(spacing: 10) {
                #if canImport(UIKit)
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCameraCapture = true
                    } else {
                        messages.append(.init(isUser: false, text: "Camera is not available on this device."))
                    }
                } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Take photo")
                #endif

                #if canImport(PhotosUI)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Choose photo")
                #else
                Button {
                    messages.append(.init(isUser: false, text: "Photo selection is not supported on this platform."))
                } label: {
                    Image(systemName: "photo.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Choose photo")
                #endif

                Button {
                    speechManager.isRecording ? speechManager.stopRecording() : speechManager.startRecording()
                    draft = speechManager.transcript
                } label: {
                    Image(systemName: speechManager.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(speechManager.isRecording ? .red : .accentColor)
                }

                TextField("Say or type what you need…", text: $draft, axis: .vertical)
                    .focused($isInputFocused)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(trimmedDraft.isEmpty && pendingAttachment == nil)

                Button(action: toggleKeyboard) {
                    Image(systemName: isInputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(isInputFocused ? "Hide keyboard" : "Show keyboard")
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
                Section {
                    Label("Please verify the priority before adding this task.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    Button("Cancel") {
                        pendingScheduledActionPayload = nil
                        showTaskDetailSheet = false
                    }
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
        let attachment = pendingAttachment
        guard !trimmed.isEmpty || attachment != nil else { return }

        let messageText = composeUserVisibleMessage(text: trimmed, attachment: attachment)
        let intentInput = composeIntentInput(text: trimmed, attachment: attachment)

        let userMessage = ChatMessage(isUser: true, text: messageText)
        messages.append(userMessage)
        draft = ""
        pendingAttachment = nil
        dismissKeyboard()

        Task { await handleIntent(for: intentInput, attachedImageDataURL: attachment?.visionImageDataURL) }
    }

    private func composeUserVisibleMessage(text: String, attachment: PendingAttachment?) -> String {
        var lines: [String] = []
        if !text.isEmpty {
            lines.append(text)
        }
        if let attachment {
            lines.append("🖼️ \(attachment.fileName)")
        }
        return lines.joined(separator: "\n")
    }

    private func composeIntentInput(text: String, attachment: PendingAttachment?) -> String {
        guard let attachment else {
            return text
        }

        let attachmentHeader = """
        [Attached image]
        Name: \(attachment.fileName)
        Size: \(attachment.fileSizeLabel)
        Type: \(attachment.fileTypeIdentifier)
        Resolution: \(attachment.imageResolutionLabel ?? "Unknown")
        """

        var segments: [String] = []
        if !text.isEmpty {
            segments.append(text)
        }

        segments.append("\(attachmentHeader)\nThe user attached an image for context.")

        return segments.joined(separator: "\n\n")
    }

    #if canImport(PhotosUI)
    private func loadPendingAttachment(from photoItem: PhotosPickerItem) async {
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    messages.append(.init(isUser: false, text: "I couldn’t read that image. Try another one."))
                }
                return
            }

            let typeIdentifier = photoItem.supportedContentTypes.first?.identifier ?? "public.image"
            let fileName = suggestedPhotoFileName(typeIdentifier: typeIdentifier)

            let attachment = await Task.detached(priority: .userInitiated) {
                buildPendingAttachment(fromImageData: data, fileName: fileName, fileTypeIdentifier: typeIdentifier)
            }.value

            await MainActor.run {
                if let attachment {
                    pendingAttachment = attachment
                    messages.append(.init(isUser: false, text: "Attached image: \(attachment.fileName)."))
                } else {
                    messages.append(.init(isUser: false, text: "I couldn’t read that image. Try another one."))
                }
            }
        } catch {
            await MainActor.run {
                messages.append(.init(isUser: false, text: "Couldn’t attach image: \(error.localizedDescription)"))
            }
        }
    }
    #endif

    #if canImport(UIKit)
    private func processCapturedImage(_ image: UIImage?) async {
        guard let image else {
            await MainActor.run {
                messages.append(.init(isUser: false, text: "No photo captured."))
            }
            return
        }

        guard let data = image.jpegData(compressionQuality: 0.92) else {
            await MainActor.run {
                messages.append(.init(isUser: false, text: "Couldn’t process captured image."))
            }
            return
        }

        let attachment = await Task.detached(priority: .userInitiated) {
            buildPendingAttachment(fromImageData: data, fileName: "CameraPhoto.jpg", fileTypeIdentifier: UTType.jpeg.identifier)
        }.value

        await MainActor.run {
            if let attachment {
                pendingAttachment = attachment
                messages.append(.init(isUser: false, text: "Attached image: \(attachment.fileName)."))
            } else {
                messages.append(.init(isUser: false, text: "Couldn’t read captured image. Try again."))
            }
        }
    }
    #endif

    private func suggestedPhotoFileName(typeIdentifier: String) -> String {
        let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg"
        return "Photo.\(ext)"
    }

    private func buildPendingAttachment(fromImageData data: Data, fileName: String, fileTypeIdentifier: String) -> PendingAttachment? {
        if let type = UTType(fileTypeIdentifier), !type.conforms(to: .image) {
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int

        var thumbnailJPEGData: Data?
        var visionJPEGData: Data?
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ]
        if let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            let outputData = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) {
                let destOptions: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: 0.75
                ]
                CGImageDestinationAddImage(destination, cgThumbnail, destOptions as CFDictionary)
                if CGImageDestinationFinalize(destination) {
                    thumbnailJPEGData = outputData as Data
                }
            }
        }

        let visionOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280
        ]
        if let visionImage = CGImageSourceCreateThumbnailAtIndex(source, 0, visionOptions as CFDictionary) {
            visionJPEGData = jpegData(from: visionImage, quality: 0.78)
            if let size = visionJPEGData?.count, size > 1_200_000 {
                visionJPEGData = jpegData(from: visionImage, quality: 0.62)
            }
            if let size = visionJPEGData?.count, size > 1_200_000 {
                visionJPEGData = jpegData(from: visionImage, quality: 0.5)
            }
        }

        let visionImageDataURL = visionJPEGData.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }

        return PendingAttachment(
            fileName: fileName,
            fileSizeBytes: data.count,
            fileTypeIdentifier: fileTypeIdentifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            thumbnailJPEGData: thumbnailJPEGData,
            visionImageDataURL: visionImageDataURL
        )
    }

    private func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }

    private func copyAgentResponse(_ message: ChatMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif

        copiedAgentMessageID = message.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedAgentMessageID == message.id {
                copiedAgentMessageID = nil
            }
        }
    }

    private func isSavedAgentResponse(_ message: ChatMessage) -> Bool {
        savedAgentItems.contains { $0.sourceMessageID == message.id }
    }

    private func toggleSavedAgentResponse(_ message: ChatMessage) {
        if let index = savedAgentItems.firstIndex(where: { $0.sourceMessageID == message.id }) {
            savedAgentItems.remove(at: index)
            return
        }

        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let messageTitle = message.responseTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTitle = messageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? SavedAgentItem.titleFrom(content: trimmed)

        let item = SavedAgentItem(
            title: savedTitle,
            content: trimmed,
            createdAt: message.timestamp,
            savedAt: Date(),
            sourceMessageID: message.id
        )
        savedAgentItems.insert(item, at: 0)
    }

    private func resolveResponseTitle(userText: String, modelTitle: String?, replyText: String) -> String {
        let bannedTitles: Set<String> = [
            "new task", "task", "answer", "response", "assistant response", "nexa"
        ]

        if let modelTitle = modelTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !modelTitle.isEmpty {
            let normalized = modelTitle.lowercased()
            if !bannedTitles.contains(normalized) {
                return String(modelTitle.prefix(70))
            }
        }

        let normalizedUserText = userText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        if !normalizedUserText.isEmpty {
            let words = normalizedUserText.split(separator: " ").map(String.init)
            let concise = words.prefix(8).joined(separator: " ")
            if !concise.isEmpty {
                if concise.count <= 70 {
                    return concise.prefix(1).uppercased() + String(concise.dropFirst())
                }
                let clipped = concise.prefix(67).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(clipped)..."
            }
        }

        return SavedAgentItem.titleFrom(content: replyText)
    }

    private func startNewChatSession() {
        ChatHistoryStore.shared.archiveCurrentSession(messages)
        ChatHistoryStore.shared.clearCurrentSession()
        messages.removeAll()

        let displayUser = userName.isEmpty ? "You" : userName
        messages.append(.init(isUser: false, text: "Hi \(displayUser)! I’m \(agentName). Tell me what you need and I’ll track and prioritize tasks for you."))

        interactionState = .idle
        draft = ""
        pendingMessage = .init()
        pendingEmail = .init()
        pendingCallRecipient = ""
        pendingAgentTask = nil
        pendingOverdueTask = nil
        pendingConflictTask = nil
        pendingConflictMatches = []
        showingAgentTaskAlert = false
        showingOverdueTaskAlert = false
        showScheduleConflictAlert = false
        isAgentThinking = false
    }
    
    private func confirmContact(_ contact: SimpleContact) async {
        var isCall = false
        var isEmail = false
        if case .clarifyingContact(_, let call, let email) = interactionState {
            isCall = call
            isEmail = email
        }
    
        if isCall {
            pendingCallRecipient = contact.number
            messages.append(.init(isUser: true, text: "Selected: \(contact.name) (\(contact.label))"))
            await triggerCall(to: pendingCallRecipient)
        } else if isEmail {
            // New Logic for Email
            if let existingEmail = contact.email, !existingEmail.isEmpty {
                 interactionState = .verifyingEmailContact(contact: contact)
                 messages.append(.init(isUser: true, text: "Selected: \(contact.name)"))
                 withAnimation {
                     messages.append(.init(isUser: false, text: "I have \(existingEmail) for \(contact.name). Is that correct?"))
                 }
            } else {
                 interactionState = .collectingEmailAddressForContact(contact: contact)
                 messages.append(.init(isUser: true, text: "Selected: \(contact.name)"))
                 withAnimation {
                     messages.append(.init(isUser: false, text: "I don't have an email address for \(contact.name). What is it?"))
                 }
            }
        } else {
            pendingMessage.recipient = contact.number
            messages.append(.init(isUser: true, text: "Selected: \(contact.name) (\(contact.label))"))
            await checkMessageCompleteness()
        }
    }
    
    private func resolveAndProceed(recipient: String, forCall: Bool = false, forEmail: Bool = false) async {
        let digits = recipient.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        // If it looks like a number (at least 7 digits) and not email
        if digits.count >= 7 && !forEmail {
            if forCall {
                pendingCallRecipient = recipient
                await triggerCall(to: recipient)
            } else {
                pendingMessage.recipient = recipient
                await checkMessageCompleteness()
            }
            return
        }
        
        // Instant email check
        if forEmail && recipient.contains("@") && recipient.contains(".") {
            pendingEmail.recipient = recipient
            await checkEmailCompleteness()
            return
        }
        
        // Check exact match first
        var candidates = await ContactHelpers().find(name: recipient)
        
        // If empty, try fuzzy top 5
        if candidates.isEmpty {
             candidates = await ContactHelpers().findTop5(query: recipient)
        }
        
        if candidates.isEmpty {
            // Truly nothing found even after fuzzy search
            if forCall {
                 interactionState = .collectingCallRecipient
                 withAnimation {
                     messages.append(.init(isUser: false, text: "I couldn't find anyone named '\(recipient)'. Who do you want to call?"))
                 }
            } else if forEmail {
                interactionState = .collectingEmailRecipient
                withAnimation {
                    messages.append(.init(isUser: false, text: "I couldn't find details for '\(recipient)'. Who is the email for?"))
                }
            } else {
                interactionState = .collectingMessageRecipient
                withAnimation {
                     messages.append(.init(isUser: false, text: "I couldn't find anyone named '\(recipient)'. Who do you want to message?"))
                }
            }
            return
        }

        // Filter based on intent
        let filtered: [SimpleContact]
        if forCall || !forEmail {
            filtered = candidates.filter { !$0.number.isEmpty }
        } else {
            filtered = candidates
        }

        if filtered.isEmpty {
             // Candidates matched name but had no suitable property (missing phone)
             messages.append(.init(isUser: false, text: "I found contacts for '\(recipient)' but they don't have phone numbers."))
             return
        }

        // Logic branching for count
        if filtered.count > 1 {
            interactionState = .clarifyingContact(candidates: filtered, forCall: forCall, forEmail: forEmail)
             withAnimation {
                messages.append(.init(isUser: false, text: "I found multiple contacts for '\(recipient)'. Please pick one:"))
            }
        } else {
             // Single result logic
             let c = filtered.first!
             let nameMatch = c.name.localizedCaseInsensitiveContains(recipient)
             
             // If name is similar OR we are in email mode (requires strict verify anyway)
             if nameMatch || forEmail {
                 if forEmail {
                      await confirmContact(c)
                 } else {
                      withAnimation { messages.append(.init(isUser: false, text: "Found \(c.name).")) }
                      if forCall {
                          pendingCallRecipient = c.number
                          await triggerCall(to: c.number)
                      } else {
                          pendingMessage.recipient = c.number
                          await checkMessageCompleteness()
                      }
                 }
             } else {
                 // Fuzzy match case (e.g. "Dave" -> "David Smith")
                 interactionState = .clarifyingContact(candidates: [c], forCall: forCall, forEmail: forEmail)
                 withAnimation {
                     messages.append(.init(isUser: false, text: "Did you mean \(c.name)?"))
                 }
             }
        }
    }
    
    // MARK: - Calling Logic

    private func triggerCall(to number: String) async {
        interactionState = .idle
        // Keep + for international calls, and digits
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "+"))
        let clean = number.components(separatedBy: allowed.inverted).joined()
        
        guard !clean.isEmpty, let url = URL(string: "tel:\(clean)") else {
             await MainActor.run {
                messages.append(.init(isUser: false, text: "Invalid number format for calling."))
             }
             return
        }
        
        await MainActor.run {
            // Apple docs: "The open(_:options:completionHandler:) method executes the completion handler on the main thread."
            // We removed canOpenURL check because 'tel' scheme often returns false without Info.plist allow-listing,
            // even though open() works fine.
            
            UIApplication.shared.open(url, options: [:]) { success in
                if success {
                     messages.append(.init(isUser: false, text: "Calling \(number)..."))
                     historyManager.addLog(actionType: "Call", description: "Start call to \(number)")
                } else {
                    #if targetEnvironment(simulator)
                    messages.append(.init(isUser: false, text: "Simulating Call to \(number)... (Simulator doesn't support calls)"))
                    historyManager.addLog(actionType: "Call", description: "Simulated call to \(number)")
                    #else
                    messages.append(.init(isUser: false, text: "Could not initiate call."))
                    #endif
                }
            }
        }
        // Cleanup
        pendingCallRecipient = ""
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

    private func checkEmailCompleteness() async {
        if pendingEmail.recipient.isEmpty {
             interactionState = .collectingEmailRecipient
             withAnimation { messages.append(.init(isUser: false, text: "Who would you like to email?")) }
             return
        }
        
        // Basic check if recipient is an email address
        let isEmail = pendingEmail.recipient.contains("@") && pendingEmail.recipient.contains(".")
        if !isEmail {
             // If not an email, we need to clarify or ask for one
             interactionState = .collectingEmailAddress
             withAnimation { messages.append(.init(isUser: false, text: "Search failed. What is \(pendingEmail.recipient)'s email address?")) }
             return
        }

        if pendingEmail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            interactionState = .collectingEmailBody
            withAnimation { messages.append(.init(isUser: false, text: "What should the email say?")) }
            return
        }
        
        if userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Attempt to fetch again if missing
            if let fetchedResult = await ContactHelpers().getMeCardName() {
                userName = fetchedResult
            }
        }
        
        let signatureName = userName.isEmpty ? "The User" : userName
        
        // NEW: Check Sufficiency
        if isAIFeatureEnabled {
            let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
            let (sufficient, question) = await intentService.checkEmailSufficiency(currentBody: pendingEmail.body, recipient: pendingEmail.recipient, senderName: signatureName, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, agentName: agentName)

            if !sufficient, let q = question {
                interactionState = .answeringEmailQuestion
                withAnimation { messages.append(.init(isUser: false, text: q)) }
                return
            }
        }
        
        await polishAndConfirmEmail()
    }

    private func polishAndConfirmEmail() async {
        withAnimation { messages.append(.init(isUser: false, text: isAIFeatureEnabled ? "Drafting professional email..." : "Preparing email draft...")) }
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
        let signatureName = userName.isEmpty ? "the user" : userName

        if !isAIFeatureEnabled {
            let signature = "\n\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)"
            pendingEmail.body = pendingEmail.body + signature
            interactionState = .confirmingEmail(pendingEmail)
            withAnimation {
                messages.append(.init(isUser: false, text: "AI drafting is unavailable without subscription. Using your original text. Reply 'Yes' to open mail app, or anything else to cancel."))
            }
            return
        }

        if let polished = await intentService.polishEmail(text: pendingEmail.body, recipient: pendingEmail.recipient, senderName: signatureName, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, agentName: agentName) {
            
            // Append AI signature with special marker for UI rendering if needed, 
            // but for email body we just append it.
            let signature = "\n\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)"
            pendingEmail.subject = polished.subject
            pendingEmail.body = polished.body + signature
            
            interactionState = .confirmingEmail(pendingEmail)
            withAnimation {
                // We display it plainly here. To show different color, we would need rich text support in ChatMessage.
                // Since ChatMessage is plain text, we will denote the signature with a separator for now.
                messages.append(.init(isUser: false, text: "Here is the draft:\n\nSubject: \(polished.subject)\n\n\(polished.body)\n\n──────────\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)\n──────────\n\nReply 'Yes' to open mail app, or something else to cancel."))
            }
        } else {
             // Fallback
             let signatureName = userName.isEmpty ? "the user" : userName
             let signature = "\n\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)"
             pendingEmail.body = pendingEmail.body + signature
             interactionState = .confirmingEmail(pendingEmail)
             withAnimation { 
                messages.append(.init(isUser: false, text: "I couldn't polish it, using raw text. Ready to send?")) 
             }
        }
    }

    private func extractEmailDraftFromAssistantText(_ assistantText: String) -> EmailDraft? {
        let lower = assistantText.lowercased()
        guard lower.contains("open mail app"), lower.contains("yes") else { return nil }

        let recipient = firstRegexMatch(in: assistantText, pattern: "(?im)^(?:to|recipient)\\s*:\\s*(.+)$", group: 1)
            ?? firstRegexMatch(in: assistantText, pattern: "(?im)^email\\s*to\\s*:\\s*(.+)$", group: 1)
            ?? pendingEmail.recipient
        let subject = firstRegexMatch(in: assistantText, pattern: "(?im)^subject\\s*:\\s*(.+)$", group: 1)
            ?? pendingEmail.subject

        var body = assistantText
        if let subjectLine = firstRegexMatch(in: assistantText, pattern: "(?im)^subject\\s*:\\s*(.+)$", group: 0),
           let subjectRange = assistantText.range(of: subjectLine) {
            body = String(assistantText[subjectRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        body = cleanDraftBodyText(body)
        if body.isEmpty { body = pendingEmail.body }

        let cleanedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedBody.isEmpty else { return nil }
        return EmailDraft(recipient: cleanedRecipient, recipientName: pendingEmail.recipientName, subject: cleanedSubject, body: cleanedBody)
    }

    private func cleanDraftBodyText(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                let lower = $0.lowercased()
                guard !lower.isEmpty else { return false }
                if lower.contains("reply") && lower.contains("yes") { return false }
                if lower.contains("open mail app") { return false }
                if lower.contains("cancel") { return false }
                if lower == "──────────" || lower == "---" { return false }
                if lower.hasPrefix("subject:") || lower.hasPrefix("to:") || lower.hasPrefix("recipient:") { return false }
                return true
            }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstRegexMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text)
        else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openPendingEmailInMailApp() {
        let recipient = pendingEmail.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = pendingEmail.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = pendingEmail.body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else {
            messages.append(.init(isUser: false, text: "I need email content before opening Mail."))
            return
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        guard let url = components.url else {
            messages.append(.init(isUser: false, text: "Couldn’t create the Mail draft URL."))
            return
        }

        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                messages.append(.init(isUser: false, text: "Opened Mail app with your draft."))
                historyManager.addLog(actionType: "Email", description: "Opened Mail draft for \(recipient.isEmpty ? "(no recipient)" : recipient)")
            } else {
                messages.append(.init(isUser: false, text: "Couldn’t open Mail app."))
            }
        }
        #elseif canImport(AppKit)
        let success = NSWorkspace.shared.open(url)
        if success {
            messages.append(.init(isUser: false, text: "Opened Mail app with your draft."))
            historyManager.addLog(actionType: "Email", description: "Opened Mail draft for \(recipient.isEmpty ? "(no recipient)" : recipient)")
        } else {
            messages.append(.init(isUser: false, text: "Couldn’t open Mail app."))
        }
        #else
        messages.append(.init(isUser: false, text: "Mail app opening is not supported on this platform."))
        #endif
    }

    private func cancelConversation() {
        interactionState = .idle
        pendingDraft = .init(title: "")
        pendingMessage = .init()
        pendingEmail = .init()
        pendingCallRecipient = ""
        showTaskDetailSheet = false
        showMessageComposer = false
        showEmailComposer = false
        withAnimation {
            messages.append(.init(isUser: false, text: "Cancelled."))
        }
    }

    private func handleIntent(for text: String, attachedImageDataURL: String? = nil) async {
        // Global cancel check
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["cancel", "stop", "never mind", "abort"].contains(lower) {
            await MainActor.run { cancelConversation() }
            return
        }

        if interactionState == .idle && isAffirmativeReply(lower) {
            let hasPendingDraft = !pendingEmail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasPendingDraft {
                interactionState = .confirmingEmail(pendingEmail)
            } else if let latestAssistant = messages.last(where: { !$0.isUser })?.text,
                      let recovered = extractEmailDraftFromAssistantText(latestAssistant) {
                pendingEmail = recovered
                interactionState = .confirmingEmail(recovered)
            }
        }

        if case .confirmingTaskConflict(let draftForTask, let actionPayload, let conflicts, let suggestions) = interactionState {
            if let optionIndex = selectedConflictSuggestionIndex(from: lower, max: suggestions.count) {
                let duration = max(draftForTask.dueDate.timeIntervalSince(draftForTask.startDate), 30 * 60)
                var updatedDraft = draftForTask
                updatedDraft.startDate = suggestions[optionIndex]
                updatedDraft.dueDate = suggestions[optionIndex].addingTimeInterval(duration)
                beginTaskConfirmationFlow(draft: updatedDraft, actionPayload: actionPayload)
                return
            }

            if lower.contains("pick") || lower.contains("myself") || lower.contains("manual") || lower.contains("new time") {
                interactionState = .collectingConflictDateTime(draft: draftForTask, actionPayload: actionPayload)
                messages.append(.init(isUser: false, text: "Sure — tell me the new date and time, for example ‘tomorrow 11am’."))
                return
            }

            if let updatedDraft = await updatedDraftWithNewDateTime(from: text, baseDraft: draftForTask) {
                beginTaskConfirmationFlow(draft: updatedDraft, actionPayload: actionPayload)
                return
            }

            if isAffirmativeReply(lower) {
                interactionState = .idle
                pendingDraft = draftForTask
                pendingScheduledActionPayload = actionPayload
                messages.append(.init(isUser: false, text: "Understood. I’ll proceed even though it overlaps with \(conflicts.first?.title ?? "another event"). Please confirm details."))
                showTaskDetailSheet = true
                return
            }

            interactionState = .collectingConflictDateTime(draft: draftForTask, actionPayload: actionPayload)
            messages.append(.init(isUser: false, text: "Please choose one of the suggested options, reply 'go ahead', or type a new date/time."))
            return
        }

        if case .collectingConflictDateTime(let draftForTask, let actionPayload) = interactionState {
            guard let updatedDraft = await updatedDraftWithNewDateTime(from: text, baseDraft: draftForTask) else {
                messages.append(.init(isUser: false, text: "I couldn’t parse that date/time. Please try like ‘tomorrow 11am’ or ‘next Tuesday at 3pm’."))
                return
            }

            beginTaskConfirmationFlow(draft: updatedDraft, actionPayload: actionPayload)
            return
        }

        // 0. Check disambiguation
        if case .clarifyingContact(let candidates, let forCall, let forEmail) = interactionState {
            if let match = candidates.first(where: { $0.name.localizedCaseInsensitiveContains(text) }) {
                await confirmContact(match)
            } else {
                if text.contains("@") && forEmail {
                    // User provided specific email during clarification
                    let email = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // We don't know WHICH contact to attach to, or if they just want to send.
                    // Let's assume just send unless they specify.
                    // Or we could try to attach to the first candidate if plausible?
                    // Safer: Just use the email.
                    pendingEmail.recipient = email
                    await checkEmailCompleteness()
                } else if forCall {
                    await resolveAndProceed(recipient: text, forCall: true)
                } else if forEmail {
                    await resolveAndProceed(recipient: text, forCall: false, forEmail: true)
                } else {
                    pendingMessage.recipient = text
                    await checkMessageCompleteness()
                }
            }
            return
        }
        
        // 0.1 Check Email Specific States
        if case .verifyingEmailContact(let contact) = interactionState {
             let lower = text.lowercased()
             // Check if user provided an email directly (override)
             if text.contains("@") {
                 let potentialEmail = text.components(separatedBy: .whitespacesAndNewlines).first(where: { $0.contains("@") }) ?? text
                 interactionState = .offeringToSaveEmail(contact: contact, email: potentialEmail)
                 withAnimation {
                     messages.append(.init(isUser: false, text: "Got it. Do you want to save \(potentialEmail) to \(contact.name)?"))
                 }
                 return
             }
             
             if lower.contains("yes") || lower.contains("correct") || lower.contains("right") || lower.contains("sure") {
                 pendingEmail.recipient = contact.email ?? ""
                 await checkEmailCompleteness()
             } else {
                 // Assume NO
                 interactionState = .collectingEmailAddressForContact(contact: contact) 
                 withAnimation {
                     messages.append(.init(isUser: false, text: "Okay, what is the correct email address for \(contact.name)?"))
                 }
             }
             return
        }

        if case .collectingEmailAddressForContact(let contact) = interactionState {
            if text.contains("@") {
                 let potentialEmail = text.components(separatedBy: .whitespacesAndNewlines).first(where: { $0.contains("@") }) ?? text
                 interactionState = .offeringToSaveEmail(contact: contact, email: potentialEmail)
                 withAnimation {
                     messages.append(.init(isUser: false, text: "Thanks. Do you want to save \(potentialEmail) to \(contact.name)?"))
                 }
            } else {
                 withAnimation {
                     messages.append(.init(isUser: false, text: "That doesn't look like an email address. Please try again or say Cancel."))
                 }
            }
            return
        }

        if case .offeringToSaveEmail(let contact, let email) = interactionState {
             let lower = text.lowercased()
             if lower.contains("yes") || lower.contains("sure") || lower.contains("ok") || lower.contains("save") || lower.contains("update") {
                 pendingEmail.recipient = email
                 if let cid = contact.contactId {
                      let success = await ContactHelpers().saveEmail(to: cid, email: email)
                      if success {
                           messages.append(.init(isUser: false, text: "Contact updated."))
                      } else {
                           messages.append(.init(isUser: false, text: "Failed to update contact (access denied or error)."))
                      }
                 } else {
                      messages.append(.init(isUser: false, text: "Could not find contact ID to update."))
                 }
                 await checkEmailCompleteness()
             } else {
                 // Assume No
                 pendingEmail.recipient = email 
                 messages.append(.init(isUser: false, text: "Okay, using \(email) just for this email."))
                 await checkEmailCompleteness()
             }
             return
        }

        if case .resolvingMissingTaskContact(let task, let type) = interactionState {
             let lower = text.lowercased()
             if lower.contains("yes") || lower.contains("add") || lower.contains("sure") || lower.contains("update") {
                 let name = task.actionPayload?.recipient ?? "Unknown"
                 interactionState = .collectingNewContactDetail(task: task, name: name, missingType: type)
                 messages.append(.init(isUser: false, text: "Okay, please enter the \(type) \(type == "phone" ? "number" : "address") for \(name)."))
             } else {
                 // Check if user provided info directly
                 if (type == "phone" && text.rangeOfCharacter(from: .decimalDigits) != nil) || (type == "email" && text.contains("@")) {
                      var updatedTask = task
                      if var p = updatedTask.actionPayload {
                         p.recipient = text
                         updatedTask.actionPayload = p
                      }
                      messages.append(.init(isUser: false, text: "Using provided info directly."))
                      interactionState = .idle
                      executeAgentTask(updatedTask) 
                 } else {
                     messages.append(.init(isUser: false, text: "Okay, task execution cancelled."))
                     interactionState = .idle
                 }
             }
             return
        }
        
        if case .collectingNewContactDetail(let task, let name, let type) = interactionState {
             // Save contact
             let saved = await ContactHelpers().createContact(name: name, phone: type == "phone" ? text : nil, email: type == "email" ? text : nil)
             
             if saved {
                 messages.append(.init(isUser: false, text: "Contact saved."))
             } else {
                 messages.append(.init(isUser: false, text: "Could not save contact, but I'll use the info for this task."))
             }
             
             let updatedTask = task // Name is still same, so executeAgentTask will resolve it now
             interactionState = .idle
             executeAgentTask(updatedTask)
             return
        }

        if case .collectingScheduledTaskContact(let name, let missingType, let draftForTask, let actionType) = interactionState {
            let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPhoneValid = trimmedInput.components(separatedBy: CharacterSet.decimalDigits.inverted).joined().count >= 7
            let isEmailValid = trimmedInput.contains("@") && trimmedInput.contains(".")

            if (missingType == "phone" && !isPhoneValid) || (missingType == "email" && !isEmailValid) {
                messages.append(.init(isUser: false, text: "Please enter a valid \(missingType == "phone" ? "phone number" : "email address") for \(name)."))
                return
            }

            let actionPayload = TaskItem.AgentAction(type: actionType, recipient: trimmedInput)
            interactionState = .idle
            messages.append(.init(isUser: false, text: "Got it. I’ll use \(trimmedInput) for \(name) and save this reminder."))
            beginTaskConfirmationFlow(draft: draftForTask, actionPayload: actionPayload)
            return
        }

        if case .collectingScheduledActionContent(let draftForTask, let actionType, let recipient, let promptLabel) = interactionState {
            let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmedInput.lowercased()
            let skipTokens = ["skip", "no", "none", "not now", "later"]

            if skipTokens.contains(lowered) {
                interactionState = .idle
                messages.append(.init(isUser: false, text: "Okay — I’ll save the reminder without \(promptLabel) content. You can still edit it later."))
                beginTaskConfirmationFlow(
                    draft: draftForTask,
                    actionPayload: .init(type: actionType, recipient: recipient)
                )
                return
            }

            guard !trimmedInput.isEmpty else {
                messages.append(.init(isUser: false, text: "Please provide the \(promptLabel) content, or reply 'skip'."))
                return
            }

            interactionState = .idle
            messages.append(.init(isUser: false, text: "Great — I saved the \(promptLabel) content for this reminder."))
            beginTaskConfirmationFlow(
                draft: draftForTask,
                actionPayload: .init(type: actionType, recipient: recipient, body: trimmedInput)
            )
            return
        }
    
        // 1. Check if we are filling a slot
        if interactionState == .collectingCallRecipient {
             await resolveAndProceed(recipient: text, forCall: true)
             return
        }

        if interactionState == .collectingEmailRecipient || interactionState == .collectingEmailAddress {
             await resolveAndProceed(recipient: text, forCall: false, forEmail: true)
             return
        }

        if interactionState == .collectingMessageRecipient {
            await resolveAndProceed(recipient: text)
            return
        }
        
        if interactionState == .collectingMessageBody {
            pendingMessage.body = text
            await checkMessageCompleteness()
            return
        }

        if interactionState == .collectingEmailBody {
            pendingEmail.body = text
            await checkEmailCompleteness()
            return
        }

        if interactionState == .answeringEmailQuestion {
            pendingEmail.body += "\n\nAdditional Details: \(text)"
            await checkEmailCompleteness()
            return
        }
        
        if case .confirmingTrackingRequest(let categoryId, let categoryName, let value, let note, let rawText, let recordDate) = interactionState {
            if isAffirmativeReply(lower) {
                trackingManager.addRecord(categoryId: categoryId, value: value, note: note ?? text, rawText: rawText, date: recordDate)
                interactionState = .idle
                messages.append(.init(isUser: false, text: "Got it! Recorded \(value) for \(categoryName)."))
            } else {
                interactionState = .idle
                messages.append(.init(isUser: false, text: "Okay, I won't record it."))
            }
            return
        }

        if !isAIFeatureEnabled && isWeatherInquiry(text) {
            let weatherReply = await weatherService.response(for: text)
            withAnimation {
                messages.append(.init(isUser: false, text: weatherReply))
            }
            return
        }
        
        if case .confirmingEmail = interactionState {
            let lower = text.lowercased()
            if isAffirmativeReply(lower) || lower.contains("send") || lower.contains("looks good") {
                interactionState = .idle
                await MainActor.run { openPendingEmailInMailApp() }
            } else {
                interactionState = .idle
                withAnimation {
                    messages.append(.init(isUser: false, text: "Email cancelled."))
                }
            }
            return
        }
    
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
        let inferred: IntentResult?
        if isAIFeatureEnabled {
            await MainActor.run {
                withAnimation {
                    isAgentThinking = true
                }
            }
            inferred = await intentService.infer(from: text, imageDataURL: attachedImageDataURL, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, userName: userName, agentName: agentName, appContext: buildAIContextSnapshot()) ?? intentAnalyzer.infer(from: text, agentName: agentName)
            await MainActor.run {
                withAnimation {
                    isAgentThinking = false
                }
            }
            lastIntentSource = intentService.usedOpenAI ? "openai" : "fallback"
            lastIntentReason = intentService.lastReason
        } else {
            inferred = intentAnalyzer.infer(from: text, agentName: agentName)
            lastIntentSource = "fallback"
            lastIntentReason = "subscription-required"
        }

        // DEBUG LOGGING
        if Bundle.main.isTestFlight {
            await MainActor.run {
                messages.append(.init(isUser: false, text: "DEBUG => Source: \(lastIntentSource), Reason: \(lastIntentReason)"))
            }
        }

        if var draft = inferred {
            if draft.action == "answer", isWeatherInquiry(text) {
                let weatherReply = await weatherService.response(for: text)
                let weatherTitle = resolveResponseTitle(userText: text, modelTitle: draft.title, replyText: weatherReply)
                withAnimation {
                    messages.append(.init(isUser: false, text: weatherReply, responseTitle: weatherTitle))
                }
                return
            }
            
            // Safety: Force 'call' action if the model returned 'task' but it looks like a call
            // Common with GPT models that are biased towards 'task' from previous prompts
            // NOTE: We only do this if it is NOT scheduled (i.e. looks like an immediate request misclassified)
            let isScheduledTask = (draft.startDate != nil && draft.startDate! > Date().addingTimeInterval(300)) || (draft.isScheduled == true)
            let lowerText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            // Safety: Force 'call' action
            if !isScheduledTask,
               (draft.action == "task" || draft.action == nil),
               let title = draft.title?.lowercased(),
               (title.starts(with: "call ") || title.starts(with: "phone ") || title.starts(with: "dial ")) {
                draft.action = "makePhoneCall"
                let name = title.replacingOccurrences(of: "call ", with: "")
                                .replacingOccurrences(of: "phone ", with: "")
                                .replacingOccurrences(of: "dial ", with: "")
                draft.recipient = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Safety: Force 'sendMessage' action if input starts with command keywords
            if !isScheduledTask,
               (draft.action == "task" || draft.action == nil),
               (lowerText.starts(with: "message ") || lowerText.starts(with: "text ") || lowerText.starts(with: "sms ") || lowerText.starts(with: "send ")) {
                 draft.action = "sendMessage"
                 // If we override, we reset recipient/body to ensure the agent asks/polishes correctly
                 // rather than using potentially confusing task details.
                 
                 // Fix: Don't nuke the recipient if the model actually found one in the 'title' or elsewhere
                 // But for now, let's trust the draft if available, else use text.
                 if draft.recipient == nil {
                     // Try to extract recipient naively if model failed?
                     // actually, we set recipient=nil to force the 'resolveAndProceed' flow which is robust.
                     draft.recipient = nil
                 }
                 draft.messageBody = text // Pass full text for polishing later
            }
            
            // Fix: If the action is sendMessage/makePhoneCall and it is NOT explicitly scheduled (no date mentioned),
            // force isScheduled to false even if the model Hallucinated a date (often defaults to "tomorrow" if unsure).
            // We trust the "text starts with command" heuristic more than the model's subtle scheduling for these commands.
            if (draft.action == "sendMessage" || draft.action == "makePhoneCall" || draft.action == "call") {
                // Heuristic: If there are NO explicit time keywords, treat as immediate even if model hallucinated a date.
                // However, we must be careful not to mistake message content ("Meet me at the park") for a scheduling instruction.
                // This is a robust heuristic: Check if the text starts with the command.
                let lower = text.lowercased()
                let startsWithCommand = lower.starts(with: "message") || lower.starts(with: "text") || lower.starts(with: "call") || lower.starts(with: "email")
                
                if startsWithCommand {
                    let timeKeywords = ["tomorrow", "later", " next week", "on monday", "on tuesday", "on wednesday", "on thursday", "on friday", "on saturday", "on sunday", " date", " in ", " min", " hour", " sec", " after "]
                    // Only check for "at" followed by digits to be safer (e.g. "at 5")
                    // This is still imperfect but better.
                    let hasStrongTime = timeKeywords.contains { lower.contains($0) } || lower.range(of: " at \\d", options: .regularExpression) != nil
                    
                    if !hasStrongTime {
                        draft.isScheduled = false
                        draft.startDate = nil
                    }
                }
            }
            
            // Call Logic
            if draft.action == "makePhoneCall" || draft.action == "call" {
                // If scheduled agent task (Explicitly marked as task or future)
                if draft.performer == "agent" && draft.isScheduled == true {
                    pendingDraft = TaskDraft(
                        title: draft.title ?? "Call \(draft.recipient ?? "someone")",
                        startDate: draft.startDate ?? Date().addingTimeInterval(3600),
                        dueDate: draft.dueDate ?? Date().addingTimeInterval(7200),
                        priority: draft.priority ?? 1,
                        tag: draft.tag ?? "Personal"
                    )
                    
                    // Attempt to resolve contact NOW if possible, or store the raw name.
                    let rawRecipient = draft.recipient ?? ""
                    var finalRecipient = rawRecipient
                    
                    // Try to resolve contact ID/number immediately for better UX
                    let candidates = await ContactHelpers().find(name: rawRecipient)
                    if let exact = candidates.first(where: { !$0.number.isEmpty }) {
                         finalRecipient = exact.name // Use the resolved name for title, but payload needs number? 
                         // Actually payload needs number for action, but name for display.
                         // Let's store the number in the payload if found.
                         // But 'recipient' in payload is often used for display in alerts.
                         // Standard: Payload.recipient = Number if known, else Name.
                         // Wait, executeAgentTask uses 'pendingMessage.recipient = payload.recipient'. So it MUST be a number or email.
                         
                         finalRecipient = exact.number
                         pendingDraft.title = "Call \(exact.name)" // Update title with real name
                    }
                    
                    let newTask = TaskItem(
                        title: pendingDraft.title,
                        tag: pendingDraft.tag,
                        startDate: pendingDraft.startDate,
                        dueDate: pendingDraft.dueDate,
                        priority: pendingDraft.priority,
                        executor: .agent,
                        actionPayload: .init(type: "makePhoneCall", recipient: finalRecipient, script: draft.callScript)
                    )
                    insertTask(newTask, announce: true)
                    return
                }
                
                // Otherwise treat as immediate
                if let raw = draft.recipient, !raw.isEmpty {
                    await resolveAndProceed(recipient: raw, forCall: true)
                } else {
                    interactionState = .collectingCallRecipient
                    withAnimation { messages.append(.init(isUser: false, text: "Who do you want to call?")) }
                }
                return
            }

            if draft.action == "sendMessage" {
                if draft.performer == "agent" && draft.isScheduled == true {
                    pendingDraft = TaskDraft(
                        title: draft.title ?? "Msg \(draft.recipient ?? "someone")",
                        startDate: draft.startDate ?? Date().addingTimeInterval(3600),
                        dueDate: draft.dueDate ?? Date().addingTimeInterval(7200),
                        priority: draft.priority ?? 1,
                        tag: draft.tag ?? "Personal"
                    )
                    
                    // Attempt to resolve contact NOW
                    let rawRecipient = draft.recipient ?? ""
                    var finalRecipient = rawRecipient
                    
                    let candidates = await ContactHelpers().find(name: rawRecipient)
                    if let exact = candidates.first(where: { !$0.number.isEmpty }) {
                         finalRecipient = exact.number
                         pendingDraft.title = "Message \(exact.name)"
                    }

                    let cleanBody = draft.messageBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if cleanBody.isEmpty {
                        interactionState = .collectingScheduledActionContent(
                            draft: pendingDraft,
                            actionType: "sendMessage",
                            recipient: finalRecipient,
                            promptLabel: "message"
                        )
                        withAnimation {
                            messages.append(.init(isUser: false, text: "What should I message \(draft.recipient ?? "them")? Reply 'skip' if you only want a reminder without content."))
                        }
                        return
                    }
                    
                    let newTask = TaskItem(
                        title: pendingDraft.title,
                        tag: pendingDraft.tag,
                        startDate: pendingDraft.startDate,
                        dueDate: pendingDraft.dueDate,
                        priority: pendingDraft.priority,
                        executor: .agent,
                        actionPayload: .init(type: "sendMessage", recipient: finalRecipient, body: cleanBody)
                    )
                    insertTask(newTask, announce: true)
                    return
                 }
                 
                 // Immediate Message
                 pendingMessage = MessageDraft(recipient: "", body: draft.messageBody ?? "")
                 if let raw = draft.recipient, !raw.isEmpty {
                    await resolveAndProceed(recipient: raw)
                 } else {
                    await checkMessageCompleteness()
                 }
                 return
            }
            
            if draft.action == "sendEmail" {
                let to = draft.recipient ?? ""
                // Trim body to ensure meaningful content
                let cleanBody = draft.messageBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                pendingEmail = EmailDraft(recipient: to, subject: draft.subject ?? "", body: cleanBody)
                
                if !to.isEmpty {
                     await resolveAndProceed(recipient: to, forCall: false, forEmail: true)
                } else {
                     interactionState = .collectingEmailRecipient
                     withAnimation { messages.append(.init(isUser: false, text: "Who would you like to email?")) }
                }
                return
            }
            
            if draft.action == "track" {
                let value = draft.trackingValue ?? 0.0
                let rawNote = draft.trackingNote ?? ""
                let recordDate = draft.startDate ?? Date()
                
                // See if AI matched to a specific category
                var matchedCategory: TrackingCategory? = nil
                if let catIdStr = draft.trackingCategoryId {
                    if let catId = UUID(uuidString: catIdStr) {
                        matchedCategory = trackingManager.categories.first { $0.id == catId }
                    } else {
                        // AI provided a name instead of UUID in categoryId field
                        matchedCategory = trackingManager.categories.first { $0.name.localizedCaseInsensitiveContains(catIdStr) }
                    }
                }
                
                if let cat = matchedCategory {
                    interactionState = .confirmingTrackingRequest(categoryId: cat.id, categoryName: cat.name, value: value, note: rawNote, rawText: text, recordDate: recordDate)
                    withAnimation {
                        messages.append(.init(isUser: false, text: "Do you want to record \(value) for \(cat.name)? (Yes/No)"))
                    }
                } else if trackingManager.categories.isEmpty {
                    withAnimation {
                        messages.append(.init(isUser: false, text: "You don't have any tracking categories set up yet. Go to 'Tracking' in the menu to add one."))
                    }
                } else {
                    let catNames = trackingManager.categories.map { $0.name }.joined(separator: ", ")
                    withAnimation {
                        messages.append(.init(isUser: false, text: "I see you want to track a value (\(value)), but I couldn't clearly match it to a category. Available categories are: \(catNames). Please specify."))
                    }
                }
                return
            }

            if draft.action == "greeting" || draft.action == "answer" {
                let statusSnapshot = shouldShowTaskStatusChart(for: text) ? currentTaskStatusSnapshot() : nil
                let fallbackReply = draft.answer ?? "I'm here to help."
                let responseTitle = resolveResponseTitle(userText: text, modelTitle: draft.title, replyText: fallbackReply)
                var latestAgentReplyText: String? = nil
                if isAIFeatureEnabled, lastIntentSource == "openai" {
                    let placeholderId = UUID()
                    var didReceiveStreamEvent = false
                    withAnimation {
                        isAgentThinking = true
                        messages.append(.init(id: placeholderId, isUser: false, text: "", taskStatusSnapshot: statusSnapshot, responseTitle: responseTitle))
                    }

                    let streamed = await intentService.streamAnswer(
                        for: text,
                        imageDataURL: attachedImageDataURL,
                        apiKey: activeKey,
                        model: storedModel,
                        useAzure: useAzure,
                        azureEndpoint: azureEndpoint,
                        userName: userName,
                        agentName: agentName,
                        appContext: buildAIContextSnapshot(),
                        onStreamEvent: {
                            if !didReceiveStreamEvent {
                                didReceiveStreamEvent = true
                                withAnimation {
                                    isAgentThinking = false
                                }
                            }
                        }
                    ) { partial in
                        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
                            let existing = messages[index]
                            messages[index] = .init(id: existing.id, isUser: existing.isUser, text: partial, timestamp: existing.timestamp, taskStatusSnapshot: existing.taskStatusSnapshot, responseTitle: existing.responseTitle)
                        }
                    }

                    if !didReceiveStreamEvent {
                        withAnimation {
                            isAgentThinking = false
                        }
                    }

                    if let streamed, !streamed.isEmpty {
                        latestAgentReplyText = streamed
                        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
                            let existing = messages[index]
                            messages[index] = .init(id: existing.id, isUser: existing.isUser, text: streamed, timestamp: existing.timestamp, taskStatusSnapshot: existing.taskStatusSnapshot, responseTitle: existing.responseTitle)
                        }
                    } else {
                        let reply = fallbackReply
                        latestAgentReplyText = reply
                        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
                            let existing = messages[index]
                            messages[index] = .init(id: existing.id, isUser: existing.isUser, text: reply, timestamp: existing.timestamp, taskStatusSnapshot: existing.taskStatusSnapshot, responseTitle: existing.responseTitle)
                        }
                    }
                } else {
                    let reply = fallbackReply
                    latestAgentReplyText = reply
                    withAnimation {
                        messages.append(.init(isUser: false, text: reply, taskStatusSnapshot: statusSnapshot, responseTitle: responseTitle))
                    }
                }

                if let latestAgentReplyText,
                   let recoveredDraft = extractEmailDraftFromAssistantText(latestAgentReplyText) {
                    pendingEmail = recoveredDraft
                    interactionState = .confirmingEmail(recoveredDraft)
                }
                return
            }

            // Scheduled reminder with call intent: verify contact before confirmation sheet
            let draftTitle = (draft.title ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
            let draftTitleLower = draftTitle.lowercased()

            if draft.action == "task" {
                draft.tag = await inferTaskTag(from: text, modelTag: draft.tag, title: draft.title)
            }

            if draft.action == "task", draftTitleLower.hasPrefix("call ") || draftTitleLower.contains(" call ") {
                let rawName = (draft.recipient?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? draft.recipient!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : extractCallTarget(from: draftTitle)

                let preparedDraft = TaskDraft(
                    title: draftTitle.isEmpty ? "Call \(rawName.isEmpty ? "contact" : rawName)" : draftTitle,
                    startDate: draft.startDate ?? Date(),
                    dueDate: draft.dueDate ?? Date().addingTimeInterval(86400),
                    priority: draft.priority ?? 1,
                    tag: draft.tag ?? "Inbox"
                )

                let digits = rawName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if digits.count >= 7 {
                    beginTaskConfirmationFlow(
                        draft: preparedDraft,
                        actionPayload: .init(type: "makePhoneCall", recipient: rawName, script: draft.callScript)
                    )
                    return
                }

                if !rawName.isEmpty {
                    let candidates = await ContactHelpers().find(name: rawName)
                    if let exact = candidates.first(where: { !$0.number.isEmpty }) {
                        var confirmedDraft = preparedDraft
                        confirmedDraft.title = "Call \(exact.name)"
                        beginTaskConfirmationFlow(
                            draft: confirmedDraft,
                            actionPayload: .init(type: "makePhoneCall", recipient: exact.number, script: draft.callScript)
                        )
                        return
                    }

                    interactionState = .collectingScheduledTaskContact(name: rawName, missingType: "phone", draft: preparedDraft, actionType: "makePhoneCall")
                    withAnimation {
                        messages.append(.init(isUser: false, text: "I couldn't find a phone number for '\(rawName)'. Please provide the number so I can store it in this reminder."))
                    }
                    return
                }
            }

            // Task Logic (User Performer)
            beginTaskConfirmationFlow(draft: TaskDraft(
                title: draft.title ?? "New Task",
                startDate: draft.startDate ?? Date(),
                dueDate: draft.dueDate ?? Date().addingTimeInterval(86400),
                priority: draft.priority ?? 1,
                tag: draft.tag ?? "Inbox"
            ), actionPayload: nil)
        } else {
            lastIntentSource = intentService.usedOpenAI ? "openai" : "fallback"
            lastIntentReason = intentService.lastReason
            promptForTaskDetails(from: text)
        }
    }

    private func finalizeMessage() async {
        interactionState = .idle
        
        let signatureName = userName.isEmpty ? "The User" : userName
        
        // Polish Message Logic
        // Always attempt to polish/extract for SMS to handle "tell him..." cases better
        withAnimation { messages.append(.init(isUser: false, text: isAIFeatureEnabled ? "Polishing message..." : "Preparing message...")) }
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
        
        // Prepare context history (last 5 messages)
        let recentHistory = messages.suffix(5).map { msg in
            "\(msg.isUser ? "User" : "Agent"): \(msg.text)"
        }.joined(separator: "\n")
        
        // Safety Clean-up logic (moved into main actor later)
        var finalBody = pendingMessage.body
          if isAIFeatureEnabled,
              let polished = await intentService.polishMessage(text: pendingMessage.body, history: recentHistory, recipient: pendingMessage.recipient, senderName: signatureName, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, agentName: agentName) {
             finalBody = polished
        }
        
        // Safety Clean-up: If AI failed OR AI didn't strip the prefix, do it manually
        // Check for common instructional prefixes
        let lowerBody = finalBody.lowercased()
        let prefixes = ["tell him ", "tell her ", "tell them ", "ask him ", "ask her ", "ask them ", "say that ", "let him know ", "let her know ", "text him ", "text her ", "message him ", "message her "]
        
        for prefix in prefixes {
             if lowerBody.hasPrefix(prefix) {
                 let prefixLength = prefix.count
                 let index = finalBody.index(finalBody.startIndex, offsetBy: prefixLength)
                 let rest = String(finalBody[index...])
                 
                 if let first = rest.first {
                     finalBody = String(first).uppercased() + String(rest.dropFirst())
                 } else {
                     finalBody = rest
                 }
                 break 
             }
        }

        // Append signature
        let signature = "\n\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)"
        if !finalBody.contains("AI powered personal assistant - \(agentName)") {
             finalBody += signature
        }
        
        let bodyToSet = finalBody
        
        await MainActor.run {
            pendingMessage.body = bodyToSet
            #if canImport(MessageUI)
            if MFMessageComposeViewController.canSendText() {
                showMessageComposer = true
            } else {
                #if targetEnvironment(simulator)
                // Simulator
                showMessageComposer = true 
                #else
                messages.append(.init(isUser: false, text: "This device cannot send messages."))
                #endif
            }
            #else
            // macOS
            messages.append(.init(isUser: false, text: "Message simulated for macOS: \(pendingMessage.body)"))
            recordSentMessageAsTask(recipient: pendingMessage.recipient, body: pendingMessage.body)
            #endif
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
        // Log message
        historyManager.addLog(actionType: "Message", description: "Sent to \(recipient): \(String(body.prefix(20)))")
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
        pendingScheduledActionPayload = nil

        // Keep the sheet open so the user can refine details if they want.
        showTaskDetailSheet = true
    }

    private func extractCallTarget(from title: String) -> String {
        let lower = title.lowercased()
        guard let range = lower.range(of: "call ") else { return "" }
        let after = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if after.isEmpty { return "" }

        let stopWords = [" tomorrow", " today", " tonight", " at ", " on ", " in ", " by "]
        let lowerAfter = after.lowercased()
        var cutIndex = after.endIndex
        for word in stopWords {
            if let stopRange = lowerAfter.range(of: word), stopRange.lowerBound < cutIndex {
                cutIndex = stopRange.lowerBound
            }
        }
        return String(after[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func shouldShowTaskStatusChart(for text: String) -> Bool {
        let lower = text.lowercased()
        let hasStatusIntent =
            lower.contains("summarize") ||
            lower.contains("summary") ||
            lower.contains("status") ||
            lower.contains("progress") ||
            lower.contains("overdue") ||
            lower.contains("upcoming") ||
            lower.contains("completed") ||
            lower.contains("work") ||
            lower.contains("personal") ||
            lower.contains("what did i do")

        let hasTaskContext =
            lower.contains("task") ||
            lower.contains("tasks") ||
            lower.contains("todo") ||
            lower.contains("reminder")

        return hasStatusIntent && (hasTaskContext || lower.contains("overdue") || lower.contains("upcoming") || lower.contains("completed") || lower.contains("work") || lower.contains("personal"))
    }

    private func normalizedTaskTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return nil }
        if lower.contains("work") || lower.contains("office") || lower.contains("client") || lower.contains("meeting") || lower.contains("project") {
            return "Work"
        }
        if lower.contains("personal") || lower.contains("home") || lower.contains("family") || lower.contains("health") || lower.contains("friend") {
            return "Personal"
        }
        return nil
    }

    private func keywordTaskTag(from text: String) -> String? {
        let lower = text.lowercased()
        let workHints = ["meeting", "client", "project", "deadline", "office", "team", "manager", "presentation", "work"]
        let personalHints = ["family", "doctor", "gym", "home", "birthday", "friend", "personal", "shopping", "booking"]

        if workHints.contains(where: { lower.contains($0) }) { return "Work" }
        if personalHints.contains(where: { lower.contains($0) }) { return "Personal" }
        return nil
    }

    private func inferTaskTag(from userText: String, modelTag: String?, title: String?) async -> String {
        if let normalized = normalizedTaskTag(modelTag) {
            return normalized
        }

        if let byKeyword = keywordTaskTag(from: "\(title ?? "") \n \(userText)") {
            return byKeyword
        }

        if isAIFeatureEnabled {
            let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
            if let aiTag = await intentService.classifyTaskTag(
                text: userText,
                title: title,
                apiKey: activeKey,
                model: storedModel,
                useAzure: useAzure,
                azureEndpoint: azureEndpoint,
                agentName: agentName
            ) {
                return aiTag
            }
        }

        return "Personal"
    }

    private func currentTaskStatusSnapshot() -> TaskStatusSnapshot {
        let now = Date()
        let appTasks = tasks.filter { $0.type == .app }

        let completed = appTasks.filter {
            $0.status == .completed || ($0.isDone && $0.status != .canceled)
        }.count

        let overdue = appTasks.filter {
            $0.isOverdue(now: now)
        }.count

        let upcoming = appTasks.filter {
            !$0.isDone && $0.status == .open && $0.dueDate >= now
        }.count

        var completedWork = 0
        var completedPersonal = 0
        var completedOther = 0
        var overdueWork = 0
        var overduePersonal = 0
        var overdueOther = 0
        var upcomingWork = 0
        var upcomingPersonal = 0
        var upcomingOther = 0

        for task in appTasks {
            let category = task.categoryLabel

            let bucket: String
            if task.status == .completed || (task.isDone && task.status != .canceled) {
                bucket = "completed"
            } else if task.isOverdue(now: now) {
                bucket = "overdue"
            } else if !task.isDone && task.status == .open && task.dueDate >= now {
                bucket = "upcoming"
            } else {
                continue
            }

            switch (bucket, category) {
            case ("completed", "Work"):
                completedWork += 1
            case ("completed", "Personal"):
                completedPersonal += 1
            case ("completed", _):
                completedOther += 1
            case ("overdue", "Work"):
                overdueWork += 1
            case ("overdue", "Personal"):
                overduePersonal += 1
            case ("overdue", _):
                overdueOther += 1
            case ("upcoming", "Work"):
                upcomingWork += 1
            case ("upcoming", "Personal"):
                upcomingPersonal += 1
            case ("upcoming", _):
                upcomingOther += 1
            default:
                break
            }
        }

        return TaskStatusSnapshot(
            completed: completed,
            overdue: overdue,
            upcoming: upcoming,
            completedWork: completedWork,
            completedPersonal: completedPersonal,
            completedOther: completedOther,
            overdueWork: overdueWork,
            overduePersonal: overduePersonal,
            overdueOther: overdueOther,
            upcomingWork: upcomingWork,
            upcomingPersonal: upcomingPersonal,
            upcomingOther: upcomingOther
        )
    }

    private func beginTaskConfirmationFlow(draft: TaskDraft, actionPayload: TaskItem.AgentAction?) {
        let candidateTask = TaskItem(
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            tag: draft.tag,
            startDate: draft.startDate,
            dueDate: draft.dueDate,
            priority: draft.priority,
            executor: .user,
            actionPayload: actionPayload
        )

        let conflicts = calendarConflicts(for: candidateTask)
        if !conflicts.isEmpty {
            let suggestions = suggestedFreeStartTimes(for: draft, maxSuggestions: 3)
            interactionState = .confirmingTaskConflict(draft: draft, actionPayload: actionPayload, conflicts: conflicts, suggestions: suggestions)
            messages.append(.init(isUser: false, text: conflictPromptMessage(for: draft, conflicts: conflicts, suggestions: suggestions)))
            return
        }

        pendingDraft = draft
        pendingScheduledActionPayload = actionPayload
        interactionState = .idle
        showTaskDetailSheet = true
    }

    private func conflictPromptMessage(for draft: TaskDraft, conflicts: [TaskItem], suggestions: [Date]) -> String {
        guard let first = conflicts.first else {
            return "This time conflicts with an existing calendar event. Do you want to proceed anyway, or provide a new date/time?"
        }

        let firstStart = first.startDate.formatted(date: .abbreviated, time: .shortened)
        let firstEnd = first.dueDate.formatted(date: .abbreviated, time: .shortened)
        var lines: [String] = []
        lines.append("I found a clash: \(draft.title) overlaps with \"\(first.title)\" (\(firstStart) - \(firstEnd)).")

        if suggestions.isEmpty {
            lines.append("No clear free slot found nearby.")
        } else {
            lines.append("Here are free time options:")
            for (index, suggestion) in suggestions.enumerated() {
                lines.append("\(index + 1). \(suggestion.formatted(date: .abbreviated, time: .shortened))")
            }
        }

        lines.append("You can tap an option, type a new date/time, or reply 'go ahead' to keep the current clashing time.")
        return lines.joined(separator: "\n")
    }

    private func selectedConflictSuggestionIndex(from lowerText: String, max: Int) -> Int? {
        guard max > 0 else { return nil }

        let options = [
            (1, ["1", "option 1", "first"]),
            (2, ["2", "option 2", "second"]),
            (3, ["3", "option 3", "third"])
        ]

        for option in options where option.0 <= max {
            if option.1.contains(where: { token in lowerText == token || lowerText.contains(token + " ") || lowerText.hasSuffix(" " + token) || lowerText.contains(" " + token + " ") }) {
                return option.0 - 1
            }
        }

        if let number = Int(lowerText.trimmingCharacters(in: .whitespacesAndNewlines)), number >= 1, number <= max {
            return number - 1
        }

        return nil
    }

    private func suggestedFreeStartTimes(for draft: TaskDraft, maxSuggestions: Int) -> [Date] {
        let duration = max(draft.dueDate.timeIntervalSince(draft.startDate), 30 * 60)
        let step: TimeInterval = 30 * 60
        let horizon: TimeInterval = 7 * 24 * 60 * 60
        var suggestions: [Date] = []

        var cursor = draft.startDate.addingTimeInterval(step)
        let end = draft.startDate.addingTimeInterval(horizon)

        while cursor <= end && suggestions.count < maxSuggestions {
            let candidate = TaskItem(
                title: draft.title,
                tag: draft.tag,
                startDate: cursor,
                dueDate: cursor.addingTimeInterval(duration),
                priority: draft.priority,
                executor: .user,
                actionPayload: nil
            )

            if calendarConflicts(for: candidate).isEmpty {
                suggestions.append(cursor)
            }

            cursor = cursor.addingTimeInterval(step)
        }

        return suggestions
    }

    private func isAffirmativeReply(_ lowerText: String) -> Bool {
        let affirmatives = ["yes", "y", "ok", "okay", "sure", "go ahead", "proceed", "confirm", "continue"]
        return affirmatives.contains { lowerText.contains($0) }
    }

    private func updatedDraftWithNewDateTime(from text: String, baseDraft: TaskDraft) async -> TaskDraft? {
        let duration = max(baseDraft.dueDate.timeIntervalSince(baseDraft.startDate), 30 * 60)
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lower.isEmpty {
            return nil
        }

        if isAIFeatureEnabled {
            let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
            if let aiStart = await intentService.parseRescheduleStartDate(
                from: text,
                currentStart: baseDraft.startDate,
                apiKey: activeKey,
                model: storedModel,
                useAzure: useAzure,
                azureEndpoint: azureEndpoint,
                agentName: agentName
            ) {
                var updated = baseDraft
                updated.startDate = aiStart
                updated.dueDate = aiStart.addingTimeInterval(duration)
                return updated
            }
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
           let start = match.date {
            var updated = baseDraft
            updated.startDate = start
            updated.dueDate = start.addingTimeInterval(duration)
            return updated
        }

        if let inferred = intentAnalyzer.infer(from: text, agentName: agentName),
           let start = inferred.startDate {
            var updated = baseDraft
            updated.startDate = start
            updated.dueDate = start.addingTimeInterval(duration)
            return updated
        }

        return nil
    }

    private func commitPendingTask() {
        let newTask = TaskItem(
            title: pendingDraft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            tag: pendingDraft.tag,
            startDate: pendingDraft.startDate,
            dueDate: pendingDraft.dueDate,
            priority: pendingDraft.priority,
            executor: .user,
            actionPayload: pendingScheduledActionPayload
        )

        let conflicts = calendarConflicts(for: newTask)
        if !conflicts.isEmpty {
            pendingConflictTask = newTask
            pendingConflictMatches = conflicts
            showScheduleConflictAlert = true
            return
        }

        insertTask(newTask, announce: true)

        pendingDraft = TaskDraft(title: "")
        pendingScheduledActionPayload = nil
        showTaskDetailSheet = false
    }

    private var scheduleConflictMessage: String {
        guard let first = pendingConflictMatches.first else {
            return "This time overlaps with an existing calendar event. You can change date/time or create anyway."
        }

        let start = first.startDate.formatted(date: .abbreviated, time: .shortened)
        let end = first.dueDate.formatted(date: .abbreviated, time: .shortened)
        return "This task overlaps with \"\(first.title)\" (\(start) - \(end)). Change date/time or create anyway."
    }

    private func calendarConflicts(for task: TaskItem) -> [TaskItem] {
        let taskStart = task.startDate
        let taskEnd = max(task.dueDate, taskStart.addingTimeInterval(30 * 60))

        func overlaps(_ existing: TaskItem) -> Bool {
            let existingStart = existing.startDate
            let existingEnd = max(existing.dueDate, existingStart.addingTimeInterval(30 * 60))
            return taskStart < existingEnd && taskEnd > existingStart
        }

        var liveConflicts: [TaskItem] = []
        if canReadCalendarEventsForConflicts() {
            let calendars = eventStore.calendars(for: .event).filter {
                $0.type != .subscription && $0.type != .birthday
            }

            let predicate = eventStore.predicateForEvents(withStart: taskStart, end: taskEnd, calendars: calendars)
            let events = eventStore.events(matching: predicate)

            liveConflicts = events
                .map { event in
                    TaskItem(
                        title: event.title ?? "Event",
                        tag: event.calendar.title,
                        startDate: event.startDate,
                        dueDate: event.endDate,
                        priority: 2,
                        type: .calendar,
                        externalId: event.eventIdentifier
                    )
                }
                .filter(overlaps)
        }

        if !liveConflicts.isEmpty {
            return liveConflicts.sorted { $0.startDate < $1.startDate }
        }

        return tasks
            .filter { $0.type == .calendar }
            .filter(overlaps)
            .sorted { $0.startDate < $1.startDate }
    }

    private func canReadCalendarEventsForConflicts() -> Bool {
        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            return status == .fullAccess
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .authorized
    }

    private func insertTask(_ newTask: TaskItem, announce: Bool) {
        tasks.append(newTask)
        reprioritize()
        scheduleReminder(for: newTask)
        // Log task creation
        historyManager.addLog(
            actionType: newTask.executor == .agent ? (newTask.actionPayload?.type ?? "Task") : "Task",
            description: "Added: \(newTask.title)"
        )
        Task { await addOrUpdateCalendarEvent(for: newTask) }

        guard announce else { return }
        
        // Improve announcement for agent tasks to confirm logic
        if newTask.executor == .agent {
            let actionType = newTask.actionPayload?.type ?? "Action"
            let recipient = newTask.actionPayload?.recipient ?? "contact"
            // Check if recipient is a raw name or number/email
            let isRaw = recipient.rangeOfCharacter(from: .decimalDigits) == nil && !recipient.contains("@")
            
            var confirmation = "Scheduled \(actionType) for \(recipient)."
            if isRaw {
                confirmation += " I'll try to resolve contact details when it's due."
            } else {
                confirmation += " Contact details resolved and ready."
            }
            withAnimation(.easeIn(duration: 0.2)) {
                messages.append(.init(isUser: false, text: confirmation))
            }
            return
        }

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

    private func addOrUpdateCalendarEvent(for task: TaskItem) async {
        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess || status == .writeOnly else { return }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .authorized else { return }
        }

        let calendarEventStartDate = CalendarEventStartDateStore.normalizedDate(from: calendarEventStartTimestamp)
        let isBeforeStartDate = task.startDate < calendarEventStartDate

        let event: EKEvent
        if let externalId = task.externalId,
           let existing = eventStore.event(withIdentifier: externalId) {
            if isBeforeStartDate {
                do {
                    try eventStore.remove(existing, span: .thisEvent)
                    await MainActor.run {
                        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                            tasks[idx].externalId = nil
                        }
                    }
                    await refreshSystemTasks()
                } catch {
                    await MainActor.run { showCalendarAlert = true }
                }
                return
            }
            event = existing
        } else {
            if isBeforeStartDate { return }
            event = EKEvent(eventStore: eventStore)
        }

        event.title = calendarEventTitle(for: task)
        guard let writableCalendar = writableEventCalendar() else {
            await MainActor.run { showCalendarAlert = true }
            return
        }
        event.calendar = writableCalendar

        let start = task.startDate
        let end = max(task.dueDate, start.addingTimeInterval(30 * 60))
        event.startDate = start
        event.endDate = end
        let marker = "PA_TASK_ID:\(task.id.uuidString)"
        let statusFlag = "PA_STATUS:\(task.status.rawValue)"
        event.notes = "\(marker)\n\(statusFlag)\nStatus: \(task.statusLabel)\nDue: \(task.dueDate.formatted(date: .abbreviated, time: .omitted)) • Priority: \(task.priorityLabel)"

        do {
            try eventStore.save(event, span: .thisEvent)
            if let savedIdentifier = event.eventIdentifier {
                await MainActor.run {
                    if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                        tasks[idx].externalId = savedIdentifier
                    }
                }
            }
            await refreshSystemTasks()
        } catch {
            await MainActor.run { showCalendarAlert = true }
        }
    }

    private func writableEventCalendar() -> EKCalendar? {
        let candidates = writableEventCalendars()

        if !preferredTaskCalendarId.isEmpty,
           let preferred = candidates.first(where: { $0.calendarIdentifier == preferredTaskCalendarId }) {
            return preferred
        }

        if let defaultCalendar = eventStore.defaultCalendarForNewEvents,
           defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }
        return candidates.first
    }

    private func writableEventCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter {
            $0.allowsContentModifications && $0.type != .subscription && $0.type != .birthday
        }
    }

    private func statusFlagDateString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func calendarSeriesIdentifier(from externalId: String) -> String {
        externalId.components(separatedBy: "/RID=").first ?? externalId
    }

    private func calendarOccurrenceStatusKey(externalId: String, date: Date) -> String {
        "\(calendarSeriesIdentifier(from: externalId))|\(statusFlagDateString(date))"
    }

    private func loadPersistedCalendarOccurrenceStatuses() {
        guard let data = UserDefaults.standard.data(forKey: calendarOccurrenceStatusesStoreKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }

        var decoded: [String: TaskItem.TaskStatus] = [:]
        for (key, value) in raw {
            if let status = TaskItem.TaskStatus(rawValue: value) {
                decoded[key] = status
            }
        }
        recentCalendarOccurrenceStatuses = decoded
    }

    private func persistCalendarOccurrenceStatuses() {
        let raw = Dictionary(uniqueKeysWithValues: recentCalendarOccurrenceStatuses.map { ($0.key, $0.value.rawValue) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: calendarOccurrenceStatusesStoreKey)
    }

    private func parseOccurrenceStatusLine(_ line: String) -> (timestamp: Int, status: TaskItem.TaskStatus)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("PA_STATUS_AT:") else { return nil }
        let payload = String(trimmed.dropFirst("PA_STATUS_AT:".count))
        guard let lastColonIndex = payload.lastIndex(of: ":") else { return nil }
        let keyPart = String(payload[..<lastColonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusPart = String(payload[payload.index(after: lastColonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = TaskItem.TaskStatus(rawValue: statusPart) else {
            return nil
        }

        let ts: Int
        if let parsedInt = Int(keyPart) {
            ts = parsedInt
        } else {
            let iso = ISO8601DateFormatter()
            guard let date = iso.date(from: keyPart) else { return nil }
            ts = Int(date.timeIntervalSince1970.rounded())
        }
        return (timestamp: ts, status: status)
    }

    private func parseOccurrenceDayStatusLine(_ line: String) -> (dayKey: String, status: TaskItem.TaskStatus)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("PA_STATUS_ON:") else { return nil }
        let payload = String(trimmed.dropFirst("PA_STATUS_ON:".count))
        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let status = TaskItem.TaskStatus(rawValue: String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return (dayKey: String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines), status: status)
    }

    private func parseTaskStatusFlag(from notes: String?, occurrenceStart: Date? = nil, occurrenceOnly: Bool = false) -> TaskItem.TaskStatus? {
        guard let notes else { return nil }

        if let occurrenceStart {
            let targetDayKey = statusFlagDateString(occurrenceStart)
            let calendar = Calendar.current
            for line in notes.split(separator: "\n") {
                if let parsed = parseOccurrenceDayStatusLine(String(line)), parsed.dayKey == targetDayKey {
                    debugCalendarStatus("parseTaskStatusFlag matched PA_STATUS_ON day=\(targetDayKey) status=\(parsed.status.rawValue)")
                    return parsed.status
                }
            }

            let targetTs = Int(occurrenceStart.timeIntervalSince1970.rounded())
            for line in notes.split(separator: "\n") {
                if let parsed = parseOccurrenceStatusLine(String(line)) {
                    if abs(parsed.timestamp - targetTs) <= 120 {
                        debugCalendarStatus("parseTaskStatusFlag matched legacy PA_STATUS_AT exact ts=\(parsed.timestamp) targetTs=\(targetTs) status=\(parsed.status.rawValue)")
                        return parsed.status
                    }

                    let parsedDate = Date(timeIntervalSince1970: TimeInterval(parsed.timestamp))
                    if calendar.isDate(parsedDate, inSameDayAs: occurrenceStart) {
                        debugCalendarStatus("parseTaskStatusFlag matched legacy PA_STATUS_AT same-day parsed=\(parsedDate.formatted(date: .abbreviated, time: .standard)) target=\(occurrenceStart.formatted(date: .abbreviated, time: .standard)) status=\(parsed.status.rawValue)")
                        return parsed.status
                    }
                }
            }

            if occurrenceOnly {
                debugCalendarStatus("parseTaskStatusFlag no occurrence match for day=\(targetDayKey); occurrenceOnly=true")
                return nil
            }
        }

        for line in notes.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("PA_STATUS:") else { continue }
            let raw = String(trimmed.dropFirst("PA_STATUS:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            debugCalendarStatus("parseTaskStatusFlag fallback PA_STATUS=\(raw)")
            return TaskItem.TaskStatus(rawValue: raw)
        }
        return nil
    }

    private func parseTaskIdentifierFlag(from notes: String?) -> UUID? {
        guard let notes else { return nil }
        for line in notes.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("PA_TASK_ID:") else { continue }
            let raw = String(trimmed.dropFirst("PA_TASK_ID:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return UUID(uuidString: raw)
        }
        return nil
    }

    private func upsertStatusFlag(in notes: String?, status: TaskItem.TaskStatus, occurrenceStart: Date? = nil) -> String {
        let existingLines = (notes ?? "").split(separator: "\n").map { String($0) }
        if let occurrenceStart {
            let occurrenceKey = statusFlagDateString(occurrenceStart)
            let prefix = "PA_STATUS_ON:\(occurrenceKey):"
            let filteredLines = existingLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) }
            let statusLine = "PA_STATUS_ON:\(occurrenceKey):\(status.rawValue)"
            if filteredLines.isEmpty {
                return statusLine
            }
            return ([statusLine] + filteredLines).joined(separator: "\n")
        }
        let filteredLines = existingLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("PA_STATUS:") }
        let statusLine = "PA_STATUS:\(status.rawValue)"
        if filteredLines.isEmpty {
            return statusLine
        }
        return ([statusLine] + filteredLines).joined(separator: "\n")
    }

    private func updateExistingCalendarEventStatusIfNeeded(for task: TaskItem) async {
        guard task.type == .calendar,
              let externalId = task.externalId,
              !externalId.isEmpty else { return }

        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess || status == .writeOnly else { return }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .authorized else { return }
        }

        guard let event = eventStore.event(withIdentifier: externalId) else { return }
        debugCalendarStatus("save-start id=\(externalId) title=\(task.title) start=\(task.startDate.formatted(date: .abbreviated, time: .standard)) status=\(task.status.rawValue)")
        event.notes = upsertStatusFlag(in: event.notes, status: task.status, occurrenceStart: task.startDate)
        debugCalendarStatus("save-notes id=\(externalId) notes=\((event.notes ?? "<nil>").replacingOccurrences(of: "\n", with: " | "))")
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            debugCalendarStatus("save-failed id=\(externalId) err=\(error.localizedDescription)")
            return
        }
        debugCalendarStatus("save-done id=\(externalId)")

        await MainActor.run {
            let key = calendarOccurrenceStatusKey(externalId: externalId, date: task.startDate)
            if task.status == .open {
                recentCalendarOccurrenceStatuses.removeValue(forKey: key)
            } else {
                recentCalendarOccurrenceStatuses[key] = task.status
            }
            persistCalendarOccurrenceStatuses()
        }

        await MainActor.run {
            for index in tasks.indices {
                guard tasks[index].type == .calendar,
                      tasks[index].externalId == task.externalId,
                      abs(tasks[index].startDate.timeIntervalSince(task.startDate)) <= 120 else {
                    continue
                }
                tasks[index].status = task.status
                tasks[index].isDone = task.status != .open
                debugCalendarStatus("local-update id=\(tasks[index].externalId ?? "") start=\(tasks[index].startDate.formatted(date: .abbreviated, time: .standard)) status=\(tasks[index].status.rawValue)")
            }
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refreshSystemTasks()
    }

    private func reconcileAppTaskStatusesFromCalendar(_ items: [TaskItem]) -> [TaskItem] {
        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess else { return items }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .authorized else { return items }
        }

        return items.map { item in
            guard item.type == .app,
                  let externalId = item.externalId,
                  let event = eventStore.event(withIdentifier: externalId),
                  let mappedTaskId = parseTaskIdentifierFlag(from: event.notes),
                  mappedTaskId == item.id,
                                    let mappedStatus = parseTaskStatusFlag(from: event.notes, occurrenceStart: item.startDate) else {
                return item
            }

            if item.status != .open && mappedStatus == .open {
                return item
            }

            var updated = item
            updated.status = mappedStatus
            updated.isDone = mappedStatus != .open
            return updated
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
        if recentCalendarOccurrenceStatuses.isEmpty {
            loadPersistedCalendarOccurrenceStatuses()
        }

        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            // Write-only permission cannot read events for sync.
            guard status == .fullAccess else {
                return []
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .authorized else {
                return []
            }
        }

        let calendar = Calendar.current
        var fetchedItems: [TaskItem] = []
        let calendarEventStartDate = CalendarEventStartDateStore.normalizedDate(from: calendarEventStartTimestamp)
        
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
            if event.startDate < calendarEventStartDate {
                // Remove sync'd app tasks from the local device calendar if they are before the start date
                if parseTaskIdentifierFlag(from: event.notes) != nil {
                    try? eventStore.remove(event, span: .thisEvent)
                }
                continue
            }

            if let mappedTaskId = parseTaskIdentifierFlag(from: event.notes) {
                let mappedStatus = parseTaskStatusFlag(from: event.notes, occurrenceStart: event.startDate) ?? .open
                let normalizedTitle = event.title?
                    .replacingOccurrences(of: "✅ ", with: "")
                    .replacingOccurrences(of: "❌ ", with: "") ?? "Task"

                fetchedItems.append(TaskItem(
                    id: mappedTaskId,
                    title: normalizedTitle,
                    isDone: mappedStatus != .open,
                    status: mappedStatus,
                    tag: event.calendar.title,
                    startDate: event.startDate,
                    dueDate: event.endDate,
                    priority: 2,
                    type: .app,
                    externalId: event.eventIdentifier
                ))
                continue
            }
            let isRecurring = (event.recurrenceRules?.isEmpty == false)
            let hasOccurrenceScopedStatus = (event.notes?.contains("PA_STATUS_ON:") == true) || (event.notes?.contains("PA_STATUS_AT:") == true)
            var mappedStatus = parseTaskStatusFlag(
                from: event.notes,
                occurrenceStart: event.startDate,
                occurrenceOnly: isRecurring || hasOccurrenceScopedStatus
            ) ?? .open
            let overrideKey = calendarOccurrenceStatusKey(externalId: event.eventIdentifier ?? "", date: event.startDate)
            if let recentOverride = recentCalendarOccurrenceStatuses[overrideKey] {
                mappedStatus = recentOverride
                debugCalendarStatus("fetch-override id=\(event.eventIdentifier ?? "<nil>") key=\(overrideKey) status=\(recentOverride.rawValue)")
            }
            if mappedStatus != .open || hasOccurrenceScopedStatus {
                debugCalendarStatus("fetch-map id=\(event.eventIdentifier ?? "<nil>") recurring=\(isRecurring) start=\(event.startDate.formatted(date: .abbreviated, time: .standard)) status=\(mappedStatus.rawValue) occScoped=\(hasOccurrenceScopedStatus) notes=\((event.notes ?? "<nil>").replacingOccurrences(of: "\n", with: " | "))")
            }
            fetchedItems.append(TaskItem(
                id: UUID(), // We generate a transient ID
                title: event.title ?? "Event",
                isDone: mappedStatus != .open,
                status: mappedStatus,
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

    private func debugCalendarStatus(_ message: String) {
        #if DEBUG
        print("[CalendarStatusDebug] \(message)")
        #endif
    }

    private func fetchReminderItems() async -> [TaskItem] {
        if #available(iOS 17, *) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            guard status == .fullAccess || status == .writeOnly else { return [] }
        } else {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            guard status == .authorized else { return [] }
        }

        let now = Date()
        let reminderCalendars = eventStore.calendars(for: .reminder)

        guard !reminderCalendars.isEmpty else { return [] }

        let predicate = eventStore.predicateForReminders(in: reminderCalendars)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let rows = (reminders ?? [])
                    .filter { !$0.isCompleted }
                    .map { reminder -> TaskItem in
                    let dueDate = reminder.dueDateComponents?.date ?? reminder.startDateComponents?.date ?? now.addingTimeInterval(3600)
                    let startDate = reminder.startDateComponents?.date ?? dueDate
                    let mappedPriority: Int
                    switch reminder.priority {
                    case 1...3: mappedPriority = 1
                    case 4...6: mappedPriority = 2
                    default: mappedPriority = 3
                    }

                        return TaskItem(
                            id: UUID(),
                            title: reminder.title,
                            isDone: reminder.isCompleted,
                            tag: reminder.calendar.title,
                            startDate: startDate,
                            dueDate: dueDate,
                            priority: mappedPriority,
                            type: .reminder,
                            externalId: reminder.calendarItemIdentifier
                        )
                    }
                continuation.resume(returning: rows)
            }
        }
    }

    private func refreshSystemTasks() async {
        await MainActor.run {
            loadTasks()
        }
        let reminderItems = await fetchReminderItems()
        await MainActor.run {
            let nonReminder = tasks.filter { $0.type != .reminder }
            let uniqueReminders = Dictionary(grouping: reminderItems, by: { $0.externalId ?? $0.id.uuidString }).compactMap { $0.value.first }
            tasks = nonReminder + uniqueReminders
            reprioritize()
            print("Loaded \(tasks.filter { $0.type == .app }.count) app tasks + \(tasks.filter { $0.type == .calendar }.count) calendar events + \(uniqueReminders.count) reminders")
        }
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
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                print("⚠️ Notification permission not authorized: \(settings.authorizationStatus.rawValue)")
                Task { @MainActor in
                    self.showNotificationAlert = true
                }
            }
        }

        let content = UNMutableNotificationContent()
        if task.executor == .agent {
            content.title = "Agent Action Due: \(task.title)"
            content.body = "Tap to execute \(task.actionPayload?.type ?? "action") for \(task.actionPayload?.recipient ?? "contact")."
        } else {
            content.title = "Task Reminder: \(task.title)"
            content.body = "Due \(task.dueDate.formatted(date: .abbreviated, time: .shortened)) • Tag: \(task.tag)"
        }
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let triggerDate = task.startDate
        let timeInterval = triggerDate.timeIntervalSinceNow
        let effectiveInterval = max(timeInterval, 1.0)

        guard timeInterval > -900 else {
            print("⚠️ Skipping notification: Time \(triggerDate) is too far in the past (\(timeInterval)s).")
            return
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: effectiveInterval, repeats: false)
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            DispatchQueue.main.async {
                let currentPending = requests.count
                let currentBadge = UIApplication.shared.applicationIconBadgeNumber
                content.badge = NSNumber(value: currentBadge + currentPending + 1)

                let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request) { error in
                    if let e = error {
                        print("Error scheduling notification: \(e)")
                    } else {
                        print("✅ Notification scheduled for \(triggerDate) (using interval \(effectiveInterval)s)")
                    }
                }
            }
        }

        Task { @MainActor in
            notificationManager.addNotification(title: content.title, body: content.body)
        }
    }

    private func setupSpeech() {
        speechManager.onSilence = { [weak speechManager] in
            guard let speechManager = speechManager else { return }
            Task { @MainActor in
                if !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                     speechManager.stopRecording() // ensure stopped
                     self.sendMessage()
                }
            }
        }
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            print("Notification status: \(settings.authorizationStatus.rawValue)")
        }
    }

    private func requestSelectedPermissions(notifications: Bool, speech: Bool, calendar: Bool, reminders: Bool, photos: Bool, camera: Bool, location: Bool) async {
        if notifications {
            _ = await requestNotificationPermission()
        }
        if speech {
            _ = await requestSpeechPermission()
            _ = await requestMicrophonePermission()
        }
        if calendar {
            await requestCalendarAccessIfNeeded()
        }
        if reminders {
            await requestRemindersAccessIfNeeded()
        }
        if photos {
            _ = await requestPhotoLibraryPermission()
        }
        if camera {
            _ = await requestCameraPermission()
        }
        if location {
            _ = await UserLocationProvider.shared.requestWhenInUseAuthorization()
        }
    }

    private func requestCameraPermission() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        switch current {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func requestPhotoLibraryPermission() async -> Bool {
        #if canImport(Photos)
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    private func requestNotificationPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    speechManager.authorizationStatus = status
                }
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func buildAIContextSnapshot() -> String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        func clipped(_ text: String, max: Int = 90) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > max else { return trimmed }
            return String(trimmed.prefix(max)) + "…"
        }

        let todayOpenTasks = tasks
            .filter { !$0.isDone && calendar.isDate($0.dueDate, inSameDayAs: now) }
            .sorted { $0.priority < $1.priority }
            .prefix(15)
            .map { "- \(clipped($0.title, max: 55)) (\($0.startDate.formatted(date: .omitted, time: .shortened)) to \($0.dueDate.formatted(date: .omitted, time: .shortened)), p\($0.priority))" }
            .joined(separator: "\n")

        let todayDoneTasks = tasks
            .filter { $0.status == .completed && calendar.isDate($0.dueDate, inSameDayAs: now) }
            .prefix(4)
            .map { "- \(clipped($0.title, max: 55))" }
            .joined(separator: "\n")

        let todayCanceledTasks = tasks
            .filter { $0.status == .canceled && calendar.isDate($0.dueDate, inSameDayAs: now) }
            .prefix(4)
            .map { "- \(clipped($0.title, max: 55))" }
            .joined(separator: "\n")

        let upcomingTasks = tasks
            .filter { !$0.isDone && $0.dueDate >= calendar.startOfDay(for: now) }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(30)
            .map { "- \(clipped($0.title, max: 55)) (\($0.startDate.formatted(date: .abbreviated, time: .shortened)) to \($0.dueDate.formatted(date: .abbreviated, time: .shortened)), p\($0.priority))" }
            .joined(separator: "\n")

        let recentActivity = historyManager.history
            .filter { $0.date >= startOfToday }
            .prefix(6)
            .map { "- [\($0.actionType)] \(clipped($0.description))" }
            .joined(separator: "\n")

        let unreadCount = notificationManager.unreadCount
        let recentNotifications = notificationManager.notifications
            .prefix(5)
            .map { "- \(clipped($0.title, max: 40)): \(clipped($0.body, max: 70)) [\($0.isRead ? "r" : "u")]" }
            .joined(separator: "\n")

        let recentChat = messages
            .suffix(4)
            .map { "\($0.isUser ? "U" : "A"): \(clipped($0.text, max: 100))" }
            .joined(separator: "\n")
            
        let trackingCats = trackingManager.categories
            .map { "- \($0.name) [Unit: \($0.unit ?? "none"), ID: \($0.id.uuidString)]" }
            .joined(separator: "\n")

        return """
        TODAY_OPEN:
        \(todayOpenTasks.isEmpty ? "- none" : todayOpenTasks)

        TODAY_DONE:
        \(todayDoneTasks.isEmpty ? "- none" : todayDoneTasks)

        TODAY_CANCELED:
        \(todayCanceledTasks.isEmpty ? "- none" : todayCanceledTasks)

        UPCOMING:
        \(upcomingTasks.isEmpty ? "- none" : upcomingTasks)

        TODAY_ACTIVITY:
        \(recentActivity.isEmpty ? "- none" : recentActivity)

        NOTIFS_UNREAD=\(unreadCount)
        \(recentNotifications.isEmpty ? "- none" : recentNotifications)

        CHAT_RECENT:
        \(recentChat.isEmpty ? "- none" : recentChat)

        TRACKING_CATEGORIES:
        \(trackingCats.isEmpty ? "- none" : trackingCats)
        """
    }

    // MARK: Helpers

    private func saveTasks() {
        let appTasks = tasks.filter {
            $0.type == .app && ($0.externalId == nil || $0.externalId?.isEmpty == true)
        }
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
        
        baseTasks = baseTasks.filter { $0.externalId == nil || $0.externalId?.isEmpty == true }

        for index in baseTasks.indices {
            if baseTasks[index].status == .open && baseTasks[index].isDone {
                baseTasks[index].status = .completed
            }
        }

        let existingAppTasks = reconcileAppTaskStatusesFromCalendar(baseTasks.filter { $0.type == .app })
        let systemItems = fetchSystemItems()

        let unsyncedById = Dictionary(uniqueKeysWithValues: existingAppTasks.map { ($0.id, $0) })
        let systemAppIds = Set(systemItems.filter { $0.type == .app }.map { $0.id })
        let remainingUnsynced = unsyncedById
            .filter { !systemAppIds.contains($0.key) }
            .map { $0.value }

        tasks = remainingUnsynced + systemItems
        
        print("Loaded \(remainingUnsynced.count) unsynced app tasks + \(systemItems.count) system items")
    }

    private func saveSavedAgentItems() {
        guard let data = try? JSONEncoder().encode(savedAgentItems) else { return }
        UserDefaults.standard.set(data, forKey: savedAgentItemsStoreKey)
    }

    private func loadSavedAgentItems() {
        guard let data = UserDefaults.standard.data(forKey: savedAgentItemsStoreKey) else {
            savedAgentItems = []
            return
        }

        do {
            savedAgentItems = try JSONDecoder().decode([SavedAgentItem].self, from: data)
        } catch {
            savedAgentItems = []
            print("Failed to load saved agent items: \(error)")
        }
    }

    private func priorityColor(_ value: Int) -> Color {
        switch value {
        case 1: return .red
        case 2: return .orange
        default: return .blue
        }
    }

    private func statusColor(for task: TaskItem) -> Color {
        if task.isOverdue() {
            return .orange
        }
        switch task.status {
        case .open: return .secondary
        case .completed: return .green
        case .canceled: return .red
        }
    }

    private func taskBackgroundColor(_ task: TaskItem) -> Color {
        if task.isOverdue() {
            return Color.red.opacity(0.18)
        }
        switch task.status {
        case .completed:
            return Color.green.opacity(0.18)
        case .canceled:
            return Color.yellow.opacity(0.22)
        case .open:
            return Color.white
        }
    }

    private func toggleTask(_ task: TaskItem) {
        guard let index = tasks.firstIndex(of: task) else { return }
        tasks[index].toggleDoneState()
        syncTaskStatusToCalendarIfNeeded(tasks[index])
    }

    private func syncTaskStatusToCalendarIfNeeded(_ task: TaskItem) {
        switch task.type {
        case .app:
            Task { await addOrUpdateCalendarEvent(for: task) }
        case .calendar:
            Task { await updateExistingCalendarEventStatusIfNeeded(for: task) }
        default:
            break
        }
    }

    private func calendarEventTitle(for task: TaskItem) -> String {
        guard task.type == .app else { return task.title }
        switch task.status {
        case .open:
            return task.title
        case .completed:
            return "✅ \(task.title)"
        case .canceled:
            return "❌ \(task.title)"
        }
    }

    private var agentAccentColor: Color {
        switch agentIconColor {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        default: return .purple
        }
    }

    private var isAIFeatureEnabled: Bool {
        #if DEBUG
        return true
        #else
        // TestFlight hack: Override subscription checks
        if Bundle.main.isTestFlight { return true }
        return subscriptionManager.hasActiveSubscription
        #endif
    }

    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func isWeatherInquiry(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let weatherTerms = ["weather", "forecast", "temperature", "rain", "snow", "humidity", "wind"]
        return weatherTerms.contains { lower.contains($0) }
    }

    private func toggleKeyboard() {
        if isInputFocused {
            dismissKeyboard()
        } else {
            isInputFocused = true
        }
    }
}

#if canImport(UIKit)
struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onComplete(nil)
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onComplete(image)
            parent.dismiss()
        }
    }
}
#endif

#if canImport(MessageUI)
import MessageUI

struct MessageComposerView: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    var recipients: [String]
    var body: String
    var completion: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        controller.modalPresentationStyle = .overFullScreen // Ensure full screen or system decision
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var parent: MessageComposerView

        init(parent: MessageComposerView) {
            self.parent = parent
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            parent.presentationMode.wrappedValue.dismiss()
            parent.completion(result)
        }
    }
}

struct EmailComposerView: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    var recipient: String
    var subject: String
    var body: String
    var completion: (MFMailComposeResult, Error?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        if MFMailComposeViewController.canSendMail() {
            let controller = MFMailComposeViewController()
            let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRecipient.isEmpty {
                controller.setToRecipients([trimmedRecipient])
            }
            controller.setSubject(subject)
            controller.setMessageBody(body, isHTML: false)
            controller.mailComposeDelegate = context.coordinator
            controller.modalPresentationStyle = .overFullScreen
            return controller
        } else {
            return MFMailComposeViewController() 
        }
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var parent: EmailComposerView

        init(parent: EmailComposerView) {
            self.parent = parent
        }

         func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.presentationMode.wrappedValue.dismiss()
            parent.completion(result, error)
        }
    }
}
#else
// Dummy implementations for platforms without MessageUI (e.g. macOS preview)
enum MessageComposeResult {
    case cancelled, sent, failed
}
enum MFMailComposeResult {
    case cancelled, saved, sent, failed
}

struct MessageComposerView: View {
    var recipients: [String]
    private var messageBody: String
    var completion: (MessageComposeResult) -> Void

    init(recipients: [String], body: String, completion: @escaping (MessageComposeResult) -> Void) {
        self.recipients = recipients
        self.messageBody = body
        self.completion = completion
    }

    var body: some View {
        VStack {
            Text("Simulated Message Composer")
            Text("To: \(recipients.joined(separator: ", "))")
            Text("Body: \(messageBody)")
            Button("Simulate Send") { completion(.sent) }
            Button("Cancel") { completion(.cancelled) }
        }
    }
}

struct EmailComposerView: View {
    var recipient: String
    var subject: String
    private var emailBody: String
    var completion: (MFMailComposeResult, Error?) -> Void

    init(recipient: String, subject: String, body: String, completion: @escaping (MFMailComposeResult, Error?) -> Void) {
        self.recipient = recipient
        self.subject = subject
        self.emailBody = body
        self.completion = completion
    }

    var body: some View {
        VStack {
            Text("Simulated Email Composer")
            Text("To: \(recipient)")
            Text("Subject: \(subject)")
            Text("Body: \(emailBody)")
            Button("Simulate Send") { completion(.sent, nil) }
            Button("Cancel") { completion(.cancelled, nil) }
        }
    }
}
#endif

#Preview {
    ContentView()
}
