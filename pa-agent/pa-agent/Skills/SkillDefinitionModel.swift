//
//  SkillDefinitionModel.swift
//  pa-agent
//
//  Mirrors the dbo.tb_Skills row returned by GET /api/skills/{user_id}.
//

import Foundation

struct SkillDefinitionModel: Identifiable, Codable, Hashable {

    // MARK: Server fields (snake_case to match JSON)
    var skill_id:        String
    var user_id:         String?
    var name:            String
    var description:     String?
    var category:        String?
    var instructions:    String
    var tool_definitions: String?   // raw JSON string — array of OpenAI tool schemas
    var is_prebuilt:     Bool
    var is_published:    Bool
    var is_enabled:      Bool
    var installed:       Bool       // true = installed from library (not owned)
    var created_at:      String
    var updated_at:      String

    // MARK: Identifiable
    var id: String { skill_id }

    // MARK: Helpers

    var categoryDisplayName: String {
        switch category?.lowercased() {
        case "productivity": return "Productivity"
        case "health":       return "Health"
        case "finance":      return "Finance"
        case "education":    return "Education"
        case "travel":       return "Travel"
        case "custom":       return "Custom"
        default:             return category?.capitalized ?? "General"
        }
    }

    var categoryColor: String {
        switch category?.lowercased() {
        case "productivity": return "blue"
        case "health":       return "green"
        case "finance":      return "orange"
        case "education":    return "purple"
        case "travel":       return "teal"
        default:             return "gray"
        }
    }

    var categoryIcon: String {
        switch category?.lowercased() {
        case "productivity": return "briefcase.fill"
        case "health":       return "heart.fill"
        case "finance":      return "dollarsign.circle.fill"
        case "education":    return "book.fill"
        case "travel":       return "airplane"
        default:             return "sparkles"
        }
    }

    /// Parsed tool definitions as [[String: Any]] for injection into the OpenAI request.
    var parsedToolDefinitions: [[String: Any]]? {
        guard let raw = tool_definitions,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr
    }

    // Convenience init for local creation (before upload)
    static func draft(name: String, description: String?, category: String?, instructions: String) -> SkillDefinitionModel {
        SkillDefinitionModel(
            skill_id:        UUID().uuidString,
            user_id:         nil,
            name:            name,
            description:     description,
            category:        category,
            instructions:    instructions,
            tool_definitions: nil,
            is_prebuilt:     false,
            is_published:    false,
            is_enabled:      true,
            installed:       false,
            created_at:      "",
            updated_at:      ""
        )
    }
}

// MARK: - Request bodies

struct SkillCreateBody: Codable {
    var name:            String
    var description:     String?
    var category:        String?
    var instructions:    String
    var tool_definitions: String?
    var is_published:    Bool = false
}

struct SkillUpdateBody: Codable {
    var name:            String?
    var description:     String?
    var category:        String?
    var instructions:    String?
    var tool_definitions: String?
    var is_published:    Bool?
    var is_enabled:      Bool?
}
