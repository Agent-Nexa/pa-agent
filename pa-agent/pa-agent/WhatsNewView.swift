//
//  WhatsNewView.swift
//  pa-agent
//
//  Shown once per app version on first launch after an install or upgrade.
//  Highlights new features and lets the user opt-in to them immediately.
//

import SwiftUI
import UserNotifications

// MARK: - WhatsNewView

struct WhatsNewView: View {

    @AppStorage(AppConfig.Keys.lastSeenAppVersion) private var lastSeenAppVersion: String = ""
    @AppStorage("morningBriefingEnabled") private var morningBriefingEnabled: Bool = true

    @Environment(\.dismiss) private var dismiss

    /// Whether the user tapped "Enable" for Morning Briefing during this session.
    @State private var briefingEnabledThisSession = false
    @State private var notificationsDenied = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.85), Color.blue.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.blue.opacity(0.25), radius: 16, x: 0, y: 6)

                    Image(systemName: "sparkles")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text("What's New in Nexa")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Version \(currentVersion)")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 48)
            .padding(.bottom, 36)

            // ── Feature list ─────────────────────────────────────────────
            VStack(spacing: 20) {
                WhatsNewFeatureRow(
                    icon: "sun.horizon.fill",
                    color: .orange,
                    title: "Morning Briefing",
                    description: "Start your day with a personalised summary of your tasks, scheduling and priorities — delivered as a daily notification."
                )
            }
            .padding(.horizontal, 24)

            // ── Morning Briefing opt-in card ─────────────────────────────
            VStack(spacing: 12) {
                if briefingEnabledThisSession || morningBriefingEnabled {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Morning Briefing is enabled")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text("You'll get a daily notification at 8:00 AM. Adjust the time in Settings → Morning Briefing.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                } else if notificationsDenied {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notifications are disabled")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Go to iPhone Settings → Nexa → Notifications to allow notifications, then enable Morning Briefing in Nexa Settings.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 10) {
                        Button(action: enableBriefing) {
                            Label("Enable Morning Briefing", systemImage: "sun.horizon.fill")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                        }
                        Text("You can also enable it later in Settings → Morning Briefing.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)

            Spacer()

            // ── Continue button ───────────────────────────────────────────
            Button(action: markSeenAndDismiss) {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: - Actions

    private func enableBriefing() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    morningBriefingEnabled = true
                    briefingEnabledThisSession = true
                    // Schedule with default 8:00 AM if not already set
                    let hour   = UserDefaults.standard.object(forKey: "morningBriefingHour")   as? Int ?? 8
                    let minute = UserDefaults.standard.object(forKey: "morningBriefingMinute") as? Int ?? 0
                    NotificationManager.shared.scheduleDailySummary(hour: hour, minute: minute)
                } else {
                    notificationsDenied = true
                }
            }
        }
    }

    private func markSeenAndDismiss() {
        lastSeenAppVersion = currentVersion
        dismiss()
    }
}

// MARK: - WhatsNewFeatureRow

private struct WhatsNewFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    WhatsNewView()
}
