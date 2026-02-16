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
