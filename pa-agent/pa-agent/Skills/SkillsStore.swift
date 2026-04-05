//
//  SkillsStore.swift
//  pa-agent
//
//  Fetches user skills from the backend, caches locally, and exposes helpers
//  that inject skill instructions + tool definitions into Azure OpenAI requests.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class SkillsStore: ObservableObject {

    static let shared = SkillsStore()
    private init() { loadCache() }

    // MARK: - Published

    @Published private(set) var skills:     [SkillDefinitionModel] = []
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastError:  String?

    // MARK: - Server URL (mirrors CreditManager pattern)

    private var serverBaseURL: String {
        UserDefaults.standard.string(forKey: AppConfig.Keys.serverURL) ?? AppConfig.Defaults.serverURL
    }

    // MARK: - Convenience views

    var prebuiltSkills: [SkillDefinitionModel] { skills.filter { $0.is_prebuilt } }
    var mySkills:       [SkillDefinitionModel] { skills.filter { !$0.is_prebuilt && !$0.installed } }
    var installedSkills: [SkillDefinitionModel] { skills.filter { $0.installed } }
    var enabledSkills:  [SkillDefinitionModel] { skills.filter { $0.is_enabled } }

    // MARK: - Prompt helpers

    /// Appended to the system prompt when skills are enabled.
    func buildInlinePromptSuffix() -> String {
        buildInlinePromptSuffix(for: enabledSkills)
    }

    /// Inject only a specific skill list, trimming each to 400 chars to control token usage.
    func buildInlinePromptSuffix(for skills: [SkillDefinitionModel]) -> String {
        guard !skills.isEmpty else { return "" }
        let sections = skills.map { skill in
            let trimmed = String(skill.instructions.prefix(400))
            return "## SKILL: \(skill.name)\n\(trimmed)"
        }.joined(separator: "\n\n")
        return "\n\n---\nACTIVE SKILLS:\n\(sections)\n---"
    }

    /// Merged OpenAI tool definitions from all enabled skills that have them.
    func buildToolDefinitions() -> [[String: Any]] {
        enabledSkills.compactMap { $0.parsedToolDefinitions }.flatMap { $0 }
    }

    // MARK: - Fetch

    func fetch(userID: String) async {
        guard !userID.isEmpty else { return }
        isFetching = true; lastError = nil
        defer { isFetching = false }

        guard let url = URL(string: "\(serverBaseURL)/api/skills/\(userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID)") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([SkillDefinitionModel].self, from: data)
            skills = decoded
            saveCache()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Create

    func create(userID: String, body: SkillCreateBody) async throws -> String {
        guard let url = URL(string: "\(serverBaseURL)/api/skills/\(userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            struct ErrResp: Decodable { var detail: String }
            if let err = try? JSONDecoder().decode(ErrResp.self, from: data) {
                throw NSError(domain: "SkillsStore", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: err.detail])
            }
            throw URLError(.badServerResponse)
        }
        struct Resp: Decodable { var skill_id: String }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        // Refresh
        await fetch(userID: userID)
        return resp.skill_id
    }

    // MARK: - Update

    func update(userID: String, skillID: String, body: SkillUpdateBody) async throws {
        guard let url = URL(string: "\(serverBaseURL)/api/skills/\(userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID)/\(skillID)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await URLSession.shared.data(for: req)
        await fetch(userID: userID)
    }

    // MARK: - Delete

    func delete(userID: String, skillID: String) async throws {
        guard let url = URL(string: "\(serverBaseURL)/api/skills/\(userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID)/\(skillID)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
        skills.removeAll { $0.skill_id == skillID }
        saveCache()
    }

    // MARK: - Toggle enable/disable

    func toggle(userID: String, skillID: String, enabled: Bool) async {
        // Optimistic local update
        if let idx = skills.firstIndex(where: { $0.skill_id == skillID }) {
            skills[idx].is_enabled = enabled
            saveCache()
        }
        guard let url = URL(string: "\(serverBaseURL)/api/skills/\(userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID)/\(skillID)/toggle?enabled=\(enabled)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Install from library

    func install(userID: String, skillID: String) async throws {
        guard let url = URL(string: "\(serverBaseURL)/api/skills/\(userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID)/install/\(skillID)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: req)
        await fetch(userID: userID)
    }

    // MARK: - Local cache

    private let cacheKey = "nexaSkillsCache"

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([SkillDefinitionModel].self, from: data)
        else { return }
        skills = decoded
    }
}
