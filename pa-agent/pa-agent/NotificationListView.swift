import SwiftUI

struct NotificationListView: View {
    @ObservedObject var manager: NotificationManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                if manager.notifications.isEmpty {
                    Text("No notifications yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.notifications) { item in
                        HStack(alignment: .top) {
                            Circle()
                                .fill(item.isRead ? Color.clear : Color.blue)
                                .frame(width: 10, height: 10)
                                .padding(.top, 5)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.body)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete(perform: manager.delete)
                }
            }
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear All") {
                        manager.clearAll()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Read All") {
                        manager.markAllAsRead()
                    }
                }
            }
            .onAppear {
                // When viewing the list, we can mark all as read automatically or let user do it?
                // For now, let's just reset the badge count if we assume viewing = read?
                // The prompt says "number to show how many notification they received".
                // Usually viewing clears the badge.
                manager.markAllAsRead()
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        }
    }
}
