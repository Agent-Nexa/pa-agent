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
    var tag: String = "General"
    var startDate: Date = .now
    var dueDate: Date = .now.addingTimeInterval(60 * 60 * 24)
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

    func infer(from text: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, userName: String?, agentName: String = "Nexa") async -> IntentResult? {
        guard let rawKey = apiKey, !rawKey.isEmpty else {
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
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
            // Azure 2024-12-01-preview + gpt-5.2/o1 models do NOT support max_tokens.
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let nowString = df.string(from: Date())

        let userContext = (userName?.isEmpty == false) ? "The user's name is \(userName!)." : ""
        
        let systemPrompt = """
        You are \(agentName), an intelligent personal assistant. \(userContext) The current time is \(nowString).
        
        Your goal is to determine the user's intent based on their input.
        
        SUPPORTED CAPABILITIES:
        1. Manage Tasks (Action: 'task'): Add a task or scheduled reminder to the task list.
        2. Send SMS (Action: 'sendMessage'): Prepare a text message.
        3. Send Email (Action: 'sendEmail'): Prepare an email.
        4. Make Phone Call (Action: 'makePhoneCall'): Prepare a phone call.
        5. Answer/Chat (Action: 'answer'): Answer questions, chat, or explain limitations.

        LOGIC RULES:
        1. IMMEDIATE ACTIONS:
           - If the user wants to Send SMS, Email, or Call RIGHT NOW: Return 'sendMessage', 'sendEmail', or 'makePhoneCall'.
           - If the user wants ANY OTHER IMMEDIATE action (e.g., "play music", "open safari", "buy stocks", "set timer"): You DO NOT have these capabilities. Return action='answer' with answer="I don't have this capability yet."
        
        2. FUTURE ACTIONS / REMINDERS:
           - If the user wants to do something later or needs a reminder: Return action='task'. populate title, dates, priority.
        
        3. INQUIRIES / GREETINGS:
           - If the user greets you or asks a question: Return action='answer' with the response in 'answer'.
        
        JSON OUTPUT FORMAT:
        {
          "action": "task" | "sendMessage" | "sendEmail" | "makePhoneCall" | "answer",
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
          "isScheduled": true | false
        }
        
        Respond ONLY with valid JSON.
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

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                usedOpenAI = false
                lastReason = "no http response"
                return fallback.infer(from: text, agentName: agentName)
            }
            guard 200..<300 ~= http.statusCode else {
                usedOpenAI = false
                lastReason = "HTTP \(http.statusCode)"
                return fallback.infer(from: text, agentName: agentName)
            }

            if let result = parseOpenAIResponse(data: data) {
                usedOpenAI = true
                lastReason = "ok"
                return result
            } else {
                usedOpenAI = false
                lastReason = "parse failure"
                return fallback.infer(from: text, agentName: agentName)
            }
        } catch {
            usedOpenAI = false
            lastReason = "network/error"
            return fallback.infer(from: text, agentName: agentName)
        }
    }

    func polishEmail(text: String, recipient: String, senderName: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, agentName: String = "Nexa") async -> (subject: String, body: String)? {
        guard let rawKey = apiKey, !rawKey.isEmpty else { return nil }
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
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let bodyPayload: [String: Any] = [
            "model": chosenModel,
            "temperature": 0.7,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "You are \(agentName), a professional email drafter. The email is to '\(recipient)' from '\(senderName)'. Based on the content and recipient, infer the relationship and tone (e.g. casual for family/friends, formal for business). Construct a professional email in JSON with 'subject' and 'body'. Sign off using '\(senderName)'."],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyPayload)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            
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
                    return (subj, b)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func polishMessage(text: String, recipient: String, senderName: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, agentName: String = "Nexa") async -> String? {
        guard let rawKey = apiKey, !rawKey.isEmpty else { return nil }
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
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let systemPrompt = """
        You are \(agentName), an intelligent assistant drafting a text message (SMS/iMessage) from '\(senderName)' to '\(recipient)'. 
        
        Your task is to extract the intended message content from the user's spoken instruction and rewrite it for SMS.
        
        CRITICAL RULES:
        1. STRIP all instructional wrappers like "tell him", "ask her", "say that", "let them know", "text him that".
        2. The output must be the checks message itself, written in the first person (as if '\(senderName)' is typing it).
        3. Do NOT include phrases like "He said...", "I should tell you...", or "The user wants me to say...".
        4. Polish the message to be concise and natural.
        
        Examples:
        - Input: "Tell him I'm running 5 mins late" -> Output: "I'm running 5 mins late"
        - Input: "Ask her if she wants to get dinner tonight" -> Output: "Do you want to get dinner tonight?"
        - Input: "Let them know I'll be there soon" -> Output: "I'll be there soon"
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

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = result["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let contentRaw = msg["content"] as? String {
                   
                let content = stripCodeFences(contentRaw)
                if let jsonData = content.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let body = dict["messageBody"] as? String {
                    return body
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func checkEmailSufficiency(currentBody: String, recipient: String, senderName: String, apiKey: String?, model: String?, useAzure: Bool, azureEndpoint: String?, agentName: String = "Nexa") async -> (sufficient: Bool, question: String?) {
         guard let rawKey = apiKey, !rawKey.isEmpty else { return (true, nil) }
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
             request.setValue(apiKey, forHTTPHeaderField: "api-key")
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
         
         do {
             let (data, response) = try await session.data(for: request)
             guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return (true, nil) }
             
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
                     return (suff, q)
                 }
             }
             return (true, nil)
         } catch {
             return (true, nil)
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
        let callScript = dict["callScript"] as? String
        let subject = dict["subject"] as? String
        let answer = dict["answer"] as? String
        
        // Delegation
        let performer = dict["performer"] as? String ?? "user"
        // Heuristic: if dates are present and action is not 'task', it might be scheduled
        let startDateStr = dict["startDate"] as? String
        let isScheduled = (startDateStr != nil)

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
            isScheduled: isScheduled
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
    
    func speak(_ text: String) {
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
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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
        
        audioEngine.stop()
        request?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
    }
}

// MARK: - View

struct ContentView: View {
    @State private var tasks: [TaskItem] = []
    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var pendingDraft: TaskDraft = .init(title: "")
    @State private var pendingMessage: MessageDraft = .init()
    @State private var pendingEmail: EmailDraft = .init()
    @State private var pendingCallRecipient: String = ""
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
    @State private var showEmailComposer = false
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://admin-mev0a1yu-eastus2.openai.azure.com/openai/deployments/gpt-5.2/chat/completions?api-version=2024-12-01-preview"
    @AppStorage("AGENT_NAME") private var agentName: String = "Nexa"
    @AppStorage("USER_NAME") private var userName: String = ""
    @AppStorage("AGENT_ICON") private var agentIcon: String = "waveform.circle.fill"
    @AppStorage("USER_ICON") private var userIcon: String = "person.circle.fill"
    @StateObject private var speechManager = SpeechManager()
    @Namespace private var scrollSpace
    private let eventStore = EKEventStore()
    private let intentAnalyzer = IntentAnalyzer()
    private let intentService = IntentService()

    @State private var taskTimer: Timer.TimerPublisher = Timer.publish(every: 60, on: .main, in: .common)
    @State private var timerCancellable: Cancellable?
    @State private var showingAgentTaskAlert = false
    @State private var pendingAgentTask: TaskItem?

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
            .onAppear {
                setupNotifications()
                setupSpeech()
            }
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
                        if let t = pendingAgentTask {
                            completeTask(t)
                            pendingAgentTask = nil
                        } else {
                            recordSentMessageAsTask(recipient: pendingMessage.recipient, body: pendingMessage.body)
                        }
                        messages.append(.init(isUser: false, text: "Message sent and logged."))
                    } else if result == .cancelled {
                        messages.append(.init(isUser: false, text: "Message cancelled."))
                    } else {
                        messages.append(.init(isUser: false, text: "Message failed."))
                    }
                    pendingMessage = .init()
                }
            }
            .sheet(isPresented: $showEmailComposer) {
                EmailComposerView(recipient: pendingEmail.recipient, subject: pendingEmail.subject, body: pendingEmail.body) { result, err in
                    if result == .sent {
                        messages.append(.init(isUser: false, text: "Email sent successfully."))
                        if let t = pendingAgentTask {
                            completeTask(t)
                            pendingAgentTask = nil
                        }
                    } else if result == .cancelled {
                         messages.append(.init(isUser: false, text: "Email cancelled."))
                    } else {
                         messages.append(.init(isUser: false, text: "Email failed to send."))
                    }
                }
            }
            .alert("Time to perform task", isPresented: $showingAgentTaskAlert, actions: {
                Button("Execute Now") {
                    if let t = pendingAgentTask { executeAgentTask(t) }
                }
                Button("Snooze") {
                    // Snooze for 1 hour
                    if let t = pendingAgentTask, let idx = tasks.firstIndex(where: { $0.id == t.id }) {
                        tasks[idx].startDate = Date().addingTimeInterval(3600)
                        saveTasks()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }, message: {
                Text(pendingAgentTask?.title ?? "A \(agentName) task is due.")
            })
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

                if messages.isEmpty {
                    let displayUser = userName.isEmpty ? "You" : userName
                    messages.append(.init(isUser: false, text: "Hi \(displayUser)! I’m \(agentName). Tell me what you need and I’ll track and prioritize tasks for you."))
                }
                loadTasks()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
                speechManager.requestPermission()
                Task { 
                    await requestCalendarAccessIfNeeded()
                    await requestRemindersAccessIfNeeded()
                }
                // Start timer
                timerCancellable = taskTimer.connect()
            }
            .onReceive(taskTimer) { time in
                checkAgentTasks(at: time)
            }
            .onChange(of: tasks) { _, _ in saveTasks() }
        }
    }

    private func checkAgentTasks(at time: Date) {
        let overdue = tasks.filter { 
            !$0.isDone && 
            $0.executor == .agent && 
            $0.startDate <= time 
        }
        
        if let first = overdue.first {
            pendingAgentTask = first
            showingAgentTaskAlert = true
        }
    }
    
    private func executeAgentTask(_ task: TaskItem) {
        guard let payload = task.actionPayload else { return }
        let signatureName = userName.isEmpty ? "the user" : userName
        let signature = "\n\nI’m \(signatureName)’s AI powered personal assistant - \(agentName)"
        
        if payload.type == "sendMessage" {
            pendingMessage = MessageDraft(recipient: payload.recipient, body: (payload.body ?? "") + signature)
            showMessageComposer = true
        } else if payload.type == "sendEmail" {
            pendingEmail = EmailDraft(recipient: payload.recipient, subject: payload.subject ?? "No Subject", body: (payload.body ?? "") + signature)
            showEmailComposer = true
        } else if payload.type == "makePhoneCall" || payload.type == "call" {
            // Check for script
            if let script = payload.script, !script.isEmpty {
                 // Speak the script instruction before calling
                let instruction = "Connecting you to \(payload.recipient). You should say: \(script)"
                speechManager.speak(instruction)
                // Small delay to let them hear it? 
                // We'll trust the user listens while the call UI comes up.
                messages.append(.init(isUser: false, text: "Script: \(script)"))
            }
            Task { await triggerCall(to: payload.recipient) }
            // For calls, we assume completion if triggering succeeds
            completeTask(task)
        }
    }
    
    private func completeTask(_ task: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].isDone = true
            reprioritize()
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
                Button("Settings") { showSettingsSheet = true }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            Spacer()
            Menu {
                Button("Tasks", action: { showTasksList = true })
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
                    
                    // Invisible footer to scroll to
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .onChange(of: messages) { oldValue, newValue in
                    // Scroll to bottom whenever messages change
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    
                    // Auto-speak new agent messages
                    if newValue.count > oldValue.count,
                       let lastMsg = newValue.last,
                       !lastMsg.isUser {
                        speechManager.speak(lastMsg.text)
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
        }
    }

    private func messageBubble(for message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser {
                Spacer()
            } else {
                Image(systemName: agentIcon)
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 32, height: 32)
                    .background(Color.purple.opacity(0.1))
                    .clipShape(Circle())
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if !message.isUser {
                    Text(agentName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
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
                if task.executor == .agent {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                         .foregroundStyle(.purple)
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

}

// MARK: - Task List Sheet (Moved to top-level)

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
            let targetDate = task.startDate
            switch selectedFilter {
            case .all:
                return true
            case .today:
                return targetDate < tomorrowStart 
            case .upcoming:
                return targetDate >= tomorrowStart && targetDate < nextWeekStart
            }
        }
        // Consistent sorting logic
        .sorted { 
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
                            Text("\(task.type == .calendar ? "📅 " : "")Start: \(task.startDate.formatted(date: .abbreviated, time: .shortened))")
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
                        (task.startDate < Date() && !task.isDone) ? Color.red.opacity(0.15) : nil
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

extension ContentView {
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
                } else {
                    #if targetEnvironment(simulator)
                    messages.append(.init(isUser: false, text: "Simulating Call to \(number)... (Simulator doesn't support calls)"))
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
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
        let (sufficient, question) = await intentService.checkEmailSufficiency(currentBody: pendingEmail.body, recipient: pendingEmail.recipient, senderName: signatureName, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, agentName: agentName)
        
        if !sufficient, let q = question {
            interactionState = .answeringEmailQuestion
            withAnimation { messages.append(.init(isUser: false, text: q)) }
            return
        }
        
        await polishAndConfirmEmail()
    }

    private func polishAndConfirmEmail() async {
        withAnimation { messages.append(.init(isUser: false, text: "Drafting professional email...")) }
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
        let signatureName = userName.isEmpty ? "the user" : userName

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

    private func handleIntent(for text: String) async {
        // Global cancel check
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["cancel", "stop", "never mind", "abort"].contains(lower) {
            await MainActor.run {
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
        
        if case .confirmingEmail = interactionState {
            let lower = text.lowercased()
            if lower.contains("yes") || lower.contains("send") || lower.contains("ok") || lower.contains("confirm") || lower.contains("looks good") {
                interactionState = .idle
                if MFMailComposeViewController.canSendMail() {
                    await MainActor.run { showEmailComposer = true }
                } else {
                    // Fallback for Simulator or no-mail-account environments
                    // We simulate "background" sending here since we can't use the Composer
                    withAnimation {
                        #if targetEnvironment(simulator)
                        messages.append(.init(isUser: false, text: "Simulated sending email to \(pendingEmail.recipient) (Simulator cannot send real emails)."))
                        #else
                        messages.append(.init(isUser: false, text: "I cannot send this email because no Mail account is set up on this device."))
                        #endif
                    }
                }
            } else {
                interactionState = .idle
                withAnimation {
                    messages.append(.init(isUser: false, text: "Email cancelled."))
                }
            }
            return
        }
    
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey

        if var draft = await intentService.infer(from: text, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, userName: userName, agentName: agentName) ?? intentAnalyzer.infer(from: text, agentName: agentName) {
            lastIntentSource = intentService.usedOpenAI ? "openai" : "fallback"
            lastIntentReason = intentService.lastReason
            
            // Safety: Force 'call' action if the model returned 'task' but it looks like a call
            // Common with GPT models that are biased towards 'task' from previous prompts
            if (draft.action == "task" || draft.action == nil),
               let title = draft.title?.lowercased(),
               (title.starts(with: "call ") || title.starts(with: "phone ") || title.starts(with: "dial ")) {
                draft.action = "makePhoneCall"
                let name = title.replacingOccurrences(of: "call ", with: "")
                                .replacingOccurrences(of: "phone ", with: "")
                                .replacingOccurrences(of: "dial ", with: "")
                draft.recipient = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Call Logic
            if draft.action == "makePhoneCall" || draft.action == "call" {
                // If immediate
                if draft.performer == "agent" && (draft.isScheduled == false || draft.isScheduled == nil) {
                    if let raw = draft.recipient, !raw.isEmpty {
                        await resolveAndProceed(recipient: raw, forCall: true)
                    } else {
                        interactionState = .collectingCallRecipient
                        withAnimation { messages.append(.init(isUser: false, text: "Who do you want to call?")) }
                    }
                    return
                }
                
                // If scheduled agent task
                if draft.performer == "agent" && draft.isScheduled == true {
                    pendingDraft = TaskDraft(
                        title: draft.title ?? "Call \(draft.recipient ?? "someone")",
                        startDate: draft.startDate ?? Date().addingTimeInterval(3600),
                        dueDate: draft.dueDate ?? Date().addingTimeInterval(7200),
                        priority: draft.priority ?? 2,
                        tag: draft.tag ?? "Personal"
                    )
                    // We need a special confirmation for agent delegation
                    // But for now, we'll use the standard task sheet, but we need to inject the executor context
                    // Since TaskDraft is simple, we might just set the state to confirm this.
                    // Let's create the task item directly if we trust the AI, or show sheet.
                    
                    // Let's assume we create it but set executor.
                    let newTask = TaskItem(
                        title: pendingDraft.title,
                        tag: pendingDraft.tag,
                        startDate: pendingDraft.startDate,
                        dueDate: pendingDraft.dueDate,
                        priority: pendingDraft.priority,
                        executor: .agent,
                        actionPayload: .init(type: "makePhoneCall", recipient: draft.recipient ?? "", script: draft.callScript)
                    )
                    insertTask(newTask, announce: true)
                    return
                }
            }

            if draft.action == "sendMessage" {
                if draft.performer == "agent" && (draft.isScheduled == false || draft.isScheduled == nil) {
                    pendingMessage = MessageDraft(recipient: "", body: draft.messageBody ?? "")
                    if let raw = draft.recipient, !raw.isEmpty {
                        await resolveAndProceed(recipient: raw)
                    } else {
                        await checkMessageCompleteness()
                    }
                    return
                }
                
                // Scheduled Message
                 if draft.performer == "agent" && draft.isScheduled == true {
                    pendingDraft = TaskDraft(
                        title: draft.title ?? "Msg \(draft.recipient ?? "someone")",
                        startDate: draft.startDate ?? Date().addingTimeInterval(3600),
                        dueDate: draft.dueDate ?? Date().addingTimeInterval(7200),
                        priority: draft.priority ?? 2,
                        tag: draft.tag ?? "Personal"
                    )
                    
                    let newTask = TaskItem(
                        title: pendingDraft.title,
                        tag: pendingDraft.tag,
                        startDate: pendingDraft.startDate,
                        dueDate: pendingDraft.dueDate,
                        priority: pendingDraft.priority,
                        executor: .agent,
                        actionPayload: .init(type: "sendMessage", recipient: draft.recipient ?? "", body: draft.messageBody)
                    )
                    insertTask(newTask, announce: true)
                    return
                 }
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
            
            if draft.action == "greeting" || draft.action == "answer" {
                let reply = draft.answer ?? "I'm here to help."
                withAnimation {
                    messages.append(.init(isUser: false, text: reply))
                }
                return
            }

            // Task Logic (User Performer)
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
        
        let signatureName = userName.isEmpty ? "The User" : userName
        
        // Polish Message Logic
        // Always attempt to polish/extract for SMS to handle "tell him..." cases better
        withAnimation { messages.append(.init(isUser: false, text: "Polishing message...")) }
        let activeKey = storedApiKey.isEmpty ? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] : storedApiKey
        
        // Safety Clean-up logic (moved into main actor later)
        var finalBody = pendingMessage.body
        if let polished = await intentService.polishMessage(text: pendingMessage.body, recipient: pendingMessage.recipient, senderName: signatureName, apiKey: activeKey, model: storedModel, useAzure: useAzure, azureEndpoint: azureEndpoint, agentName: agentName) {
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
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
}

#if canImport(MessageUI)
import MessageUI

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

struct EmailComposerView: UIViewControllerRepresentable {
    var recipient: String
    var subject: String
    var body: String
    var completion: (MFMailComposeResult, Error?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        if MFMailComposeViewController.canSendMail() {
            let controller = MFMailComposeViewController()
            controller.setToRecipients([recipient])
            controller.setSubject(subject)
            controller.setMessageBody(body, isHTML: false)
            controller.mailComposeDelegate = context.coordinator
            return controller
        } else {
            return MFMailComposeViewController() 
        }
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var completion: (MFMailComposeResult, Error?) -> Void

        init(completion: @escaping (MFMailComposeResult, Error?) -> Void) {
            self.completion = completion
        }

         func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true) {
                self.completion(result, error)
            }
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
