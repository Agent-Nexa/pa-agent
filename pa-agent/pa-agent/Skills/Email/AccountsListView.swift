//
//  AccountsListView.swift
//  pa-agent
//
//  Lists all connected email accounts with per-account remove action and
//  an "Add Account" button that opens AddAccountView.
//
//  Used inside EmailSkillSetupView (initial setup) and as a toolbar sheet
//  from EmailInboxView (post-setup account management).
//

import SwiftUI

struct AccountsListView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = EmailAccountsManager.shared

    @State private var showAddAccount = false

    /// When true the view shows a "Done" button so it can be used as an independent sheet.
    var showDoneButton: Bool = false

    /// Called when an account is added or removed (used by EmailSkillSetupView).
    var onChange: (() -> Void)?

    var body: some View {
        List {
            if manager.accounts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No accounts connected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .listRowBackground(Color.clear)
            } else {
                // Group by provider
                let gmailAccounts   = manager.accounts(for: .gmail)
                let outlookAccounts = manager.accounts(for: .outlook)

                if !gmailAccounts.isEmpty {
                    Section(header: Text("Google")) {
                        ForEach(gmailAccounts) { account in
                            accountRow(account)
                        }
                    }
                }

                if !outlookAccounts.isEmpty {
                    Section(header: Text("Microsoft")) {
                        ForEach(outlookAccounts) { account in
                            accountRow(account)
                        }
                    }
                }
            }

            // Add Account button row
            Section {
                Button {
                    showAddAccount = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 30, height: 30)
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Text("Add Account")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showAddAccount, onDismiss: { onChange?() }) {
            AddAccountView()
        }
        .toolbar {
            if showDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Account row

    private func accountRow(_ account: EmailAccount) -> some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack {
                Circle()
                    .fill(providerColor(account.provider).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: providerIcon(account.provider))
                    .font(.system(size: 16))
                    .foregroundStyle(providerColor(account.provider))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(account.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                manager.removeAccount(account)
                onChange?()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                manager.removeAccount(account)
                onChange?()
            } label: {
                Label("Remove Account", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func providerColor(_ provider: EmailProvider) -> Color {
        switch provider {
        case .gmail:   return .red
        case .outlook: return .blue
        }
    }

    private func providerIcon(_ provider: EmailProvider) -> String {
        switch provider {
        case .gmail:   return "envelope.fill"
        case .outlook: return "envelope.badge.fill"
        }
    }
}
