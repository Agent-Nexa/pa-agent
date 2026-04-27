//
//  AddAccountView.swift
//  pa-agent
//
//  "Add Account" sheet for the Email skill.
//  Mirrors the design in the screenshot: provider rows with icon, label and chevron.
//

import SwiftUI

struct AddAccountView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = EmailAccountsManager.shared

    @State private var connectingProvider: EmailProvider?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // ── Email accounts ─────────────────────────────────────
                Section {
                    providerRow(
                        provider: .gmail,
                        icon: "envelope.fill",
                        iconColor: .red,
                        title: "Gmail",
                        subtitle: "Connect a Google / Gmail account"
                    )

                    providerRow(
                        provider: .outlook,
                        icon: "envelope.badge.fill",
                        iconColor: .blue,
                        title: "Outlook / Microsoft 365",
                        subtitle: "Personal Outlook, Hotmail or work M365 account"
                    )
                } header: {
                    Text("Email Account")
                } footer: {
                    Text("Add your Microsoft Account, Google Account, iCloud Account, etc.")
                }

                // ── Error ──────────────────────────────────────────────
                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    .listRowBackground(Color.clear)
                }

                // ── Privacy note ───────────────────────────────────────
                Section {
                    Label(
                        "Emails are processed on-device or via your configured AI endpoint only.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(manager.isAddingAccount)
        }
    }

    // MARK: - Provider row

    @ViewBuilder
    private func providerRow(
        provider: EmailProvider,
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String
    ) -> some View {
        Button {
            connectingProvider = provider
            errorMessage = nil
            Task {
                do {
                    try await EmailAccountsManager.shared.addAccount(provider: provider)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
                connectingProvider = nil
            }
        } label: {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if connectingProvider == provider {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connectingProvider != nil)
    }
}
