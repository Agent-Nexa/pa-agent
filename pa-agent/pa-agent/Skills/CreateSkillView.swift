//
//  CreateSkillView.swift
//  pa-agent
//
//  Create or edit a user-defined agent skill.
//  The "AI Refine" button rewrites the user's plain-English description
//  into a precise SKILL.md-style instruction body using Azure OpenAI.
//

import SwiftUI
import Combine

struct CreateSkillView: View {

    // Pass nil to create, or a skill to edit
    var editingSkill: SkillDefinitionModel? = nil
    var userID: String
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var skillsStore = SkillsStore.shared

    // AI config from app settings (same keys as ContentView)
    @AppStorage("OPENAI_API_KEY")         private var apiKey:       String = ""
    @AppStorage("OPENAI_MODEL")           private var model:         String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE")       private var useAzure:      Bool   = true
    @AppStorage("OPENAI_AZURE_ENDPOINT")  private var azureEndpoint: String = ""
    @AppStorage("AGENT_NAME")             private var agentName:     String = "Nexa"

    // Form fields
    @State private var name:         String = ""
    @State private var description:  String = ""
    @State private var category:     String = "productivity"
    @State private var instructions: String = ""
    @State private var isPublished:  Bool   = false

    // State
    @State private var isSaving:    Bool = false
    @State private var isRefining:  Bool = false
    @State private var errorMsg:    String?
    @State private var showDiscard  = false

    private let categories = [
        ("productivity", "Productivity", "briefcase.fill"),
        ("health",       "Health",       "heart.fill"),
        ("finance",      "Finance",      "dollarsign.circle.fill"),
        ("education",    "Education",    "book.fill"),
        ("travel",       "Travel",       "airplane"),
        ("custom",       "Custom",       "sparkles"),
    ]

    private struct SkillTemplate {
        let name: String
        let category: String
        let description: String
        let instructions: String
        let icon: String
        let color: Color
    }

    private let templates: [SkillTemplate] = [
        SkillTemplate(
            name: "Morning Briefing",
            category: "productivity",
            description: "Summarise my day every morning",
            instructions: "When I say 'good morning' or ask about my day, check my pending tasks and tracking data, then give me a concise summary: what's overdue, what's due today, and my top 3 priorities. Keep it under 5 bullet points.",
            icon: "sunrise.fill",
            color: .orange
        ),
        SkillTemplate(
            name: "Focus Mode",
            category: "productivity",
            description: "Keep me on track, reject distractions",
            instructions: "If I ask about anything not related to my current tasks or the topic I'm working on, politely decline and redirect me back to my priorities. Remind me of my top open task if I go off-topic.",
            icon: "scope",
            color: .blue
        ),
        SkillTemplate(
            name: "Spend Tracker",
            category: "finance",
            description: "Log and summarise spending from messages",
            instructions: "When I mention spending money (e.g. 'spent $50 on lunch', 'paid $120 for electricity'), extract the amount, category, and date, create a task to log it, and keep a running total when I ask 'how much have I spent this week'.",
            icon: "dollarsign.circle.fill",
            color: .green
        ),
        SkillTemplate(
            name: "Meeting Prep",
            category: "productivity",
            description: "Brief me before meetings",
            instructions: "When I say 'I have a meeting with [person/topic]', pull any related tasks, notes, or email threads I mention, and give me a 3-bullet prep summary: key context, open items, and what I need from them.",
            icon: "person.2.fill",
            color: .purple
        ),
    ]

    private var isEditing: Bool { editingSkill != nil }
    private var isDirty: Bool {
        name != (editingSkill?.name ?? "") ||
        description != (editingSkill?.description ?? "") ||
        instructions != (editingSkill?.instructions ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Templates (new skills only)
                if !isEditing {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(templates, id: \.name) { tpl in
                                    Button {
                                        name         = tpl.name
                                        description  = tpl.description
                                        category     = tpl.category
                                        instructions = tpl.instructions
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Image(systemName: tpl.icon)
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundStyle(tpl.color)
                                            Text(tpl.name)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(tpl.description)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(width: 130, alignment: .leading)
                                        .padding(10)
                                        .background(tpl.color.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(tpl.color.opacity(0.25), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Start from a Template")
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }

                // Header hint
                Section {
                    Label(
                        isEditing
                            ? "Edit your skill's instructions. Tap \"AI Refine\" to let the AI improve them."
                            : "Describe what you want this skill to do in plain language, then tap \"AI Refine\" to let the AI turn it into precise instructions.",
                        systemImage: "lightbulb.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                // Basic info
                Section("Skill Details") {
                    TextField("Name (e.g. Budget Guard)", text: $name)

                    TextField("Short description (optional)", text: $description)
                        .foregroundStyle(.secondary)

                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.0) { id, label, _ in
                            Label(label, systemImage: categories.first(where: { $0.0 == id })?.2 ?? "sparkles")
                                .tag(id)
                        }
                    }
                }

                // Instructions editor
                Section {
                    ZStack(alignment: .topLeading) {
                        if instructions.isEmpty {
                            Text("e.g. When I mention my budget or spending, always check my tracking categories and compare this month's total to last month before answering. If I haven't set a budget category, suggest I create one.")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $instructions)
                            .font(.body)
                            .frame(minHeight: 180)
                    }

                    Button {
                        Task { await refineWithAI() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text(isRefining ? "Refining…" : "AI Refine Instructions")
                            Spacer()
                            if isRefining { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRefining)
                    .foregroundStyle(.purple)

                } header: {
                    Text("Instructions")
                } footer: {
                    Text("The AI will rewrite your description into a structured SKILL.md-style instruction set.")
                        .font(.caption)
                }

                // Error
                if let err = errorMsg {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Skill" : "New Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { showDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              isSaving)
                    .fontWeight(.semibold)
                }
            }
            .onAppear { populateFromEditing() }
            .confirmationDialog("Discard changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
    }

    // MARK: - Populate for editing

    private func populateFromEditing() {
        guard let s = editingSkill else { return }
        name         = s.name
        description  = s.description ?? ""
        category     = s.category ?? "productivity"
        instructions = s.instructions
        isPublished  = s.is_published
    }

    // MARK: - AI Refine

    private func refineWithAI() async {
        isRefining = true; errorMsg = nil
        defer { isRefining = false }

        let raw = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let metaPrompt = """
        You are a skills framework expert. The user wants to create an AI agent skill.
        Rewrite the following plain-English description as a structured, precise skill instruction body in SKILL.md style.
        Use clear sections: ## Behaviour (bullet points), ## Tone (if relevant), ## Constraints.
        Keep it concise — under 200 words. Do NOT add YAML frontmatter. Output only the instruction body text.

        User description:
        \(raw)
        """

        // Call Azure OpenAI directly (chat completions)
        let activeKey  = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModel = model.isEmpty ? "gpt-4o" : model

        guard useAzure || !activeKey.isEmpty,
              let endpointURL = URL(string: azureEndpoint.isEmpty ? "" : azureEndpoint)
        else {
            errorMsg = "Azure OpenAI not configured. Set endpoint in Settings → Profile."
            return
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !activeKey.isEmpty { request.setValue(activeKey, forHTTPHeaderField: "api-key") }

        let body: [String: Any] = [
            "model": activeModel,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": "You are a precise technical writer."],
                ["role": "user",   "content": metaPrompt]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
               !content.isEmpty {
                instructions = content.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                errorMsg = "AI refine failed — check your API settings."
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true; errorMsg = nil
        defer { isSaving = false }

        let trimName  = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimInstr = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimDesc  = description.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if let existing = editingSkill {
                try await skillsStore.update(
                    userID:  userID,
                    skillID: existing.skill_id,
                    body: SkillUpdateBody(
                        name:         trimName,
                        description:  trimDesc.isEmpty ? nil : trimDesc,
                        category:     category,
                        instructions: trimInstr,
                        is_published: isPublished
                    )
                )
            } else {
                _ = try await skillsStore.create(
                    userID: userID,
                    body: SkillCreateBody(
                        name:         trimName,
                        description:  trimDesc.isEmpty ? nil : trimDesc,
                        category:     category,
                        instructions: trimInstr,
                        is_published: isPublished
                    )
                )
            }
            onSaved?()
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
