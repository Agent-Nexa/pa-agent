import Foundation
import SwiftUI
import Combine
import UserNotifications

struct NotificationItem: Identifiable, Codable {
    let id: UUID
    let title: String
    let body: String
    let date: Date
    var isRead: Bool
    
    init(id: UUID = UUID(), title: String, body: String, date: Date = Date(), isRead: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.date = date
        self.isRead = isRead
    }
}

class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()
    @Published var notifications: [NotificationItem] = []
    private let maxStoredNotifications = 200

    var unreadCount: Int {
        notifications.lazy.filter { !$0.isRead }.count
    }
    
    override init() {
        super.init()
        load()
        // Reset badge on launch? Or maybe just when viewing the list.
        // Let's rely on the view to reset.
    }
    
    func addNotification(title: String, body: String) {
        let item = NotificationItem(title: title, body: body)
        notifications.insert(item, at: 0)
        trimNotificationsIfNeeded()
        save()
        updateBadgeCount()
    }
    
    func markAllAsRead() {
        for i in 0..<notifications.count {
            notifications[i].isRead = true
        }
        save()
        updateBadgeCount()
    }
    
    func delete(at offsets: IndexSet) {
        notifications.remove(atOffsets: offsets)
        save()
        updateBadgeCount()
    }
    
    func clearAll() {
        notifications.removeAll()
        save()
        updateBadgeCount()
    }
    
    private func updateBadgeCount() {
        let currentUnreadCount = unreadCount
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(currentUnreadCount) { error in
                if let error = error {
                    print("Error setting badge count: \(error)")
                }
            }
        }
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(encoded, forKey: "NotificationHistory")
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: "NotificationHistory"),
           let decoded = try? JSONDecoder().decode([NotificationItem].self, from: data) {
            notifications = decoded
            trimNotificationsIfNeeded()
        }
    }

    private func trimNotificationsIfNeeded() {
        guard notifications.count > maxStoredNotifications else { return }
        notifications = Array(notifications.prefix(maxStoredNotifications))
    }
}

extension NotificationManager {
    
    /// Call this when the app launches or when the user sends a message to the agent
    func scheduleInactivityReminder(days: Double = 3.0) {
        let center = UNUserNotificationCenter.current()
        let identifier = "nexa_inactivity_reminder"
        
        // Cancel the previously scheduled reminder (resetting the timer)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        
        // Determine the dynamically configured agent name
        let agentName = UserDefaults.standard.string(forKey: AppConfig.Keys.agentName) ?? AppConfig.Defaults.agentName
        
        // Create the engaging content
        let content = UNMutableNotificationContent()
        content.title = "\(agentName) misses you! 👋"
        content.body = "Quiet day? Check in with \(agentName) to brainstorm your next big idea or see what's new."
        content.sound = .default
        
        // Set the trigger time
        let timeInterval: TimeInterval = days * 24 * 60 * 60
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        
        // Schedule the notification locally
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule reminder: \(error.localizedDescription)")
            }
        }
    }
    
    /// Optional: Call this if they explicitly log out, or if you want to turn the reminder off entirely
    func cancelInactivityReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["nexa_inactivity_reminder"])
    }

    /// Fires a local OS notification informing the user that shared content arrived.
    /// Safe to call from inside the main app (e.g. after background processing).
    func scheduleSharedContentNotification(sourceApp: String, contentType: String, contentPreview: String) {
        let content = UNMutableNotificationContent()
        let agentName = UserDefaults.standard.string(forKey: AppConfig.Keys.agentName) ?? AppConfig.Defaults.agentName
        content.title = "\(agentName) received new content"
        let knownSource = !sourceApp.isEmpty && sourceApp != "Shared"
        switch contentType {
        case "image":
            content.body = knownSource ? "Image from \(sourceApp) — tap to open" : "New image — tap to open"
        case "url":
            content.body = knownSource ? "Link from \(sourceApp): \(contentPreview)" : "New link: \(contentPreview)"
        default:
            let preview = contentPreview.prefix(80)
            content.body = knownSource ? "From \(sourceApp): \(preview)" : String(preview)
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request  = UNNotificationRequest(
            identifier: "nexa_shared_main_\(UUID().uuidString)",
            content:    content,
            trigger:    trigger
        )
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    // MARK: - Daily Morning Briefing

    static let dailySummaryIdentifier = "nexa_daily_summary"

    /// Schedule (or reschedule) the repeating daily morning briefing notification.
    /// - Parameters:
    ///   - hour: Hour in local time (0–23). Default 8.
    ///   - minute: Minute in local time (0–59). Default 0.
    func scheduleDailySummary(hour: Int = 8, minute: Int = 0) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailySummaryIdentifier])

        let agentName = UserDefaults.standard.string(forKey: AppConfig.Keys.agentName) ?? AppConfig.Defaults.agentName

        let content = UNMutableNotificationContent()
        content.title = "Good morning! ☀️"
        content.body = "\(agentName) has your daily briefing ready — tasks, overdue items, and drafted messages."
        content.sound = .default
        content.userInfo = ["deepLink": "morningBriefing"]

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: Self.dailySummaryIdentifier, content: content, trigger: trigger)

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(request) { error in
                if let error = error {
                    print("Failed to schedule daily summary: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Cancel the daily morning briefing notification.
    func cancelDailySummary() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dailySummaryIdentifier])
    }

    func scheduleReceiptDetectedNotification(count: Int) {
        guard count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "New Receipts in Photos"
        content.body = "You have \(count) new receipt\(count == 1 ? "" : "s"). Open the app to confirm importing into Spending."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "pa_receipt_detected_\(UUID().uuidString)", content: content, trigger: trigger)

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Failed to schedule receipt notification: \(error.localizedDescription)")
                }
            }
        }
    }
}
