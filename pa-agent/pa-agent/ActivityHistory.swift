import Foundation
import SwiftUI
import Combine

struct ActivityLog: Identifiable, Codable {
    let id: UUID
    let date: Date
    let actionType: String // "Call", "Message", "Email", "Task"
    let description: String
    
    init(id: UUID = UUID(), date: Date = Date(), actionType: String, description: String) {
        self.id = id
        self.date = date
        self.actionType = actionType
        self.description = description
    }
}

class ActivityHistoryManager: NSObject, ObservableObject {
    @Published var history: [ActivityLog] = []
    
    override init() {
        super.init()
        self.load()
    }
    
    func addLog(actionType: String, description: String) {
        let log = ActivityLog(actionType: actionType, description: description)
        history.insert(log, at: 0)
        save()
    }
    
    func clearHistory() {
        history.removeAll()
        save()
    }
    
    func delete(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        save()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: "ActivityHistory")
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: "ActivityHistory"),
           let decoded = try? JSONDecoder().decode([ActivityLog].self, from: data) {
            history = decoded
        }
    }
}
