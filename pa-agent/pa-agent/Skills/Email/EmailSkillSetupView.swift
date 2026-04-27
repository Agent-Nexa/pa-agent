//
//  EmailSkillSetupView.swift
//  pa-agent
//
//  Shown the first time the Email skill is toggled on.
//  Embeds AccountsListView so the user can add one or more Gmail / Outlook accounts.
//

import SwiftUI

struct EmailSkillSetupView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = EmailAccountsManager.shared

    /// Called with `true` when at least one account is connected and the user taps Enable.
    var onComplete: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 10) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                    Text("Email Assistant")
                        .font(.title2.bold())
                    Text("Connect your email accounts so Nexa can read your inbox, triage messages, and draft replies on your behalf.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 20)

                // Accounts list (reusable component)
                AccountsListView(showDoneButton: false)
            }
            .navigationTitle("Set Up Email Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onComplete(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enable") {
                        onComplete(manager.hasAnyAccount)
                        dismiss()
                    }
                    .disabled(!manager.hasAnyAccount)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
