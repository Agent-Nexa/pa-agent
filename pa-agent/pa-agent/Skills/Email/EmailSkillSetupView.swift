//
//  EmailSkillSetupView.swift
//  pa-agent
//
//  Shown the first time the Email skill is toggled on.
//  The user connects Gmail and/or Outlook before the skill activates.
//

import SwiftUI
import Combine

struct EmailSkillSetupView: View {

    @Environment(\.dismiss) private var dismiss

    @StateObject private var gmailService   = GmailService.shared
    @StateObject private var outlookService = OutlookService.shared

    @State private var gmailError:   String?
    @State private var outlookError: String?
    @State private var isConnectingGmail   = false
    @State private var isConnectingOutlook = false

    /// Called with `true` when at least one account is connected.
    var onComplete: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                // Header
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.blue)
                        Text("Email Assistant")
                            .font(.title2.bold())
                        Text("Connect your email accounts so Nexa can read your inbox, triage messages, and draft replies on your behalf.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                // Gmail
                Section {
                    if gmailService.isSignedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gmail connected")
                                    .font(.subheadline.weight(.semibold))
                                Text(gmailService.connectedEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") {
                                gmailService.signOut()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            isConnectingGmail = true
                            gmailError = nil
                            Task {
                                do {
                                    try await GmailService.shared.signIn()
                                } catch {
                                    gmailError = error.localizedDescription
                                }
                                isConnectingGmail = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope.fill")
                                    .foregroundStyle(.red)
                                Text("Connect Gmail")
                                Spacer()
                                if isConnectingGmail {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isConnectingGmail)

                        if let err = gmailError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Google")
                } footer: {
                    if !gmailService.isSignedIn {
                        Text("Requires Gmail OAuth. A browser will open for sign-in.")
                            .font(.caption)
                    }
                }

                // Outlook
                Section {
                    if outlookService.isSignedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Outlook connected")
                                    .font(.subheadline.weight(.semibold))
                                Text(outlookService.connectedEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") {
                                outlookService.signOut()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            isConnectingOutlook = true
                            outlookError = nil
                            Task {
                                do {
                                    try await OutlookService.shared.signIn()
                                } catch {
                                    outlookError = error.localizedDescription
                                }
                                isConnectingOutlook = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope.badge.fill")
                                    .foregroundStyle(.blue)
                                Text("Connect Outlook / Hotmail")
                                Spacer()
                                if isConnectingOutlook {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isConnectingOutlook)

                        if let err = outlookError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Microsoft")
                } footer: {
                    if !outlookService.isSignedIn {
                        Text("Works with personal Outlook, Hotmail, and Microsoft 365 accounts.")
                            .font(.caption)
                    }
                }

                // Privacy
                Section {
                    Label("Emails are processed on-device or via your configured AI endpoint only.", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
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
                        onComplete(gmailService.isSignedIn || outlookService.isSignedIn)
                        dismiss()
                    }
                    .disabled(!gmailService.isSignedIn && !outlookService.isSignedIn)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
