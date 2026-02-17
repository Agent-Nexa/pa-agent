import SwiftUI

struct ActivityHistoryView: View {
    @ObservedObject var historyManager: ActivityHistoryManager
    @State private var showClearConfirmation = false
    
    var body: some View {
        List {
            Section("Activity History") {
                if historyManager.history.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historyManager.history) { log in
                        VStack(alignment: .leading) {
                            HStack {
                                Image(systemName: iconForType(log.actionType))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(.blue)
                                Text(log.actionType.capitalized)
                                    .font(.headline)
                                Spacer()
                                Text(log.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(log.description)
                                .font(.body)
                        }
                    }
                    .onDelete { indexSet in
                        historyManager.delete(at: indexSet)
                    }

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear Activity History", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Activity History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear All") {
                    showClearConfirmation = true
                }
                .disabled(historyManager.history.isEmpty)
            }
        }
        .confirmationDialog("Clear all activity history?", isPresented: $showClearConfirmation) {
            Button("Clear History", role: .destructive) {
                historyManager.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
    
    func iconForType(_ type: String) -> String {
        switch type.lowercased() {
        case "call": return "phone.fill"
        case "message": return "message.fill"
        case "email": return "envelope.fill"
        case "task": return "checkmark.circle.fill"
        case "greeting": return "hand.wave.fill"
        default: return "clock"
        }
    }
}
