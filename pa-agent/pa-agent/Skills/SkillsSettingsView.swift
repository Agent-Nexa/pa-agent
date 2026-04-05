//
//  SkillsSettingsView.swift
//  pa-agent
//
//  Lists all agent skills with enable/disable toggles.
//  Embedded in SettingsView as the "Skills" tab.
//

import SwiftUI
import Combine

struct SkillsSettingsView: View {

    var userID: String
    var onRequestEmailSetup: () -> Void = {}
    var onRequestCreateSkill: () -> Void = {}
    var onRequestEditSkill: (SkillDefinitionModel) -> Void = { _ in }

    @StateObject private var skillsManager  = SkillsManager.shared
    @StateObject private var skillsStore    = SkillsStore.shared
    @StateObject private var gmailService   = GmailService.shared
    @StateObject private var outlookService = OutlookService.shared

    var body: some View {
        Group {
            prebuiltSkillsSection
            mySkillsSection
            deviceSkillsSection
        }
        .task { await skillsStore.fetch(userID: userID) }
    }

    // ── Pre-built skills ─────────────────────────────────────────────────
    @ViewBuilder
    private var prebuiltSkillsSection: some View {
        if !skillsStore.prebuiltSkills.isEmpty {
            Section {
                ForEach(skillsStore.prebuiltSkills, id: \.skill_id) { skill in
                    cloudSkillRow(skill)
                }
            } header: {
                Text("Pre-built Skills")
            }
        }
    }

    // ── My custom skills ─────────────────────────────────────────────────
    @ViewBuilder
    private var mySkillsSection: some View {
        Section {
            ForEach(skillsStore.mySkills, id: \.skill_id) { skill in
                cloudSkillRow(skill)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { try? await skillsStore.delete(userID: userID, skillID: skill.skill_id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { onRequestEditSkill(skill) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
            let enabledCount = skillsStore.mySkills.filter { $0.is_enabled }.count
            if enabledCount >= 6 {
                Label("\(enabledCount) skills active — disable some for best performance.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button { onRequestCreateSkill() } label: {
                Label("Add Skill", systemImage: "plus.circle.fill")
                    .foregroundStyle(enabledCount >= 10 ? Color.secondary : Color.accentColor)
            }
            .disabled(enabledCount >= 10)
        } header: {
            Text("My Skills")
        } footer: {
            Text("Write natural-language instructions and let AI refine them into precise agent behaviours.")
                .font(.caption)
        }
    }

    // ── Device-level integration toggles ─────────────────────────────────
    @ViewBuilder
    private var deviceSkillsSection: some View {
        ForEach(AgentSkill.allCases) { skill in
            skillRow(skill)
        }
    }

    // MARK: - Cloud skill row (pre-built + custom)

    private func swiftColor(_ name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "green":  return .green
        case "orange": return .orange
        case "purple": return .purple
        case "teal":   return .teal
        default:       return .gray
        }
    }

    @ViewBuilder
    private func cloudSkillRow(_ skill: SkillDefinitionModel) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(swiftColor(skill.categoryColor).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: skill.categoryIcon)
                    .foregroundStyle(swiftColor(skill.categoryColor))
                    .font(.system(size: 18, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.subheadline.weight(.semibold))
                    if skill.is_prebuilt {
                        Text("Built-in")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                if let desc = skill.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { skill.is_enabled },
                set: { newVal in
                    Task { try? await skillsStore.toggle(userID: userID, skillID: skill.skill_id, enabled: newVal) }
                }
            ))
            .labelsHidden()
        }
    }

    // MARK: - Device skill row (email, messaging)

    @ViewBuilder
    private func skillRow(_ skill: AgentSkill) -> some View {
        Section {
            // Toggle header row
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(skill.accentColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: skill.iconName)
                        .foregroundStyle(skill.accentColor)
                        .font(.system(size: 18, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { skillsManager.isEnabled(skill) },
                    set: { newVal in handleToggle(skill, newVal) }
                ))
                .labelsHidden()
            }

            // Per-skill status / config rows
            if skillsManager.isEnabled(skill) {
                skillDetail(skill)
            }

        } header: {
            Text(skill.displayName)
        }
    }

    // MARK: - Detail rows when device skill is enabled

    @ViewBuilder
    private func skillDetail(_ skill: AgentSkill) -> some View {
        switch skill {
        case .email:
            // Gmail row
            HStack {
                Image(systemName: "envelope.fill").foregroundStyle(.red).frame(width: 20)
                Text("Gmail")
                Spacer()
                if gmailService.isSignedIn {
                    Text(gmailService.connectedEmail)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Disconnect") { gmailService.signOut() }
                        .font(.caption).foregroundStyle(.red).buttonStyle(.plain)
                } else {
                    Button("Connect") { Task { try? await GmailService.shared.signIn() } }
                        .font(.caption).foregroundStyle(.blue).buttonStyle(.plain)
                }
            }

            // Outlook row
            HStack {
                Image(systemName: "envelope.badge.fill").foregroundStyle(.blue).frame(width: 20)
                Text("Outlook")
                Spacer()
                if outlookService.isSignedIn {
                    Text(outlookService.connectedEmail)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Disconnect") { outlookService.signOut() }
                        .font(.caption).foregroundStyle(.red).buttonStyle(.plain)
                } else {
                    Button("Connect") { Task { try? await OutlookService.shared.signIn() } }
                        .font(.caption).foregroundStyle(.blue).buttonStyle(.plain)
                }
            }

        case .messaging:
            HStack {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.green).frame(width: 20)
                Text("Use the iOS Share Sheet in any app and choose Nexa to forward messages here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Toggle handler

    private func handleToggle(_ skill: AgentSkill, _ newValue: Bool) {
        if newValue && skill.requiresSetup {
            onRequestEmailSetup()
        } else {
            skillsManager.setEnabled(skill, newValue)
        }
    }
}

// MARK: - Standalone sheet wrapper (presented from ContentView toolbar)

struct SkillsSheetView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var showEmailSkillSetup = false
    @State private var showCreateSkill     = false
    @State private var skillToEdit: SkillDefinitionModel? = nil

    var body: some View {
        NavigationStack {
            Form {
                SkillsSettingsView(
                    userID: authManager.email,
                    onRequestEmailSetup:  { showEmailSkillSetup = true },
                    onRequestCreateSkill: { showCreateSkill = true },
                    onRequestEditSkill:   { skillToEdit = $0 }
                )
            }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showEmailSkillSetup) {
            EmailSkillSetupView { connected in
                SkillsManager.shared.setEnabled(.email, connected)
            }
        }
        .sheet(isPresented: $showCreateSkill) {
            CreateSkillView(userID: authManager.email) {
                Task { await SkillsStore.shared.fetch(userID: authManager.email) }
            }
        }
        .sheet(item: $skillToEdit) { skill in
            CreateSkillView(editingSkill: skill, userID: authManager.email) {
                Task { await SkillsStore.shared.fetch(userID: authManager.email) }
            }
        }
    }
}
