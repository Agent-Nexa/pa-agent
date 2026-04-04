import SwiftUI

struct OverdueTasksSheet: View {
    @Binding var tasks: [TaskItem]
    @Binding var selectedIDs: Set<UUID>
    let onComplete: (TaskItem) -> Void
    let onPostpone: (TaskItem) -> Void
    let onCancel: (TaskItem) -> Void
    let onDismiss: () -> Void

    var selectedCount: Int {
        tasks.filter { selectedIDs.contains($0.id) }.count
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(tasks) { task in
                    HStack(spacing: 12) {
                        // Checkbox
                        Button {
                            if selectedIDs.contains(task.id) {
                                selectedIDs.remove(task.id)
                            } else {
                                selectedIDs.insert(task.id)
                            }
                        } label: {
                            Image(systemName: selectedIDs.contains(task.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .font(.title3)
                                .foregroundColor(selectedIDs.contains(task.id) ? .green : .secondary)
                        }
                        .buttonStyle(.plain)

                        // Task info
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.body)
                            Text("Due: \(task.dueDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIDs.contains(task.id) {
                            selectedIDs.remove(task.id)
                        } else {
                            selectedIDs.insert(task.id)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            onPostpone(task)
                            withAnimation {
                                tasks.removeAll { $0.id == task.id }
                                selectedIDs.remove(task.id)
                            }
                        } label: {
                            Label("Postpone 1h", systemImage: "clock.arrow.circlepath")
                        }
                        .tint(.orange)

                        Button(role: .destructive) {
                            onCancel(task)
                            withAnimation {
                                tasks.removeAll { $0.id == task.id }
                                selectedIDs.remove(task.id)
                            }
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Overdue Tasks (\(tasks.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Dismiss") {
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selectedCount == tasks.count ? "Deselect All" : "Select All") {
                        if selectedCount == tasks.count {
                            selectedIDs = []
                        } else {
                            selectedIDs = Set(tasks.map { $0.id })
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let toComplete = tasks.filter { selectedIDs.contains($0.id) }
                    toComplete.forEach { onComplete($0) }
                    withAnimation {
                        tasks.removeAll { selectedIDs.contains($0.id) }
                        selectedIDs = []
                    }
                    if tasks.isEmpty {
                        onDismiss()
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text(selectedCount > 0
                             ? "Complete Selected (\(selectedCount))"
                             : "Complete Selected")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(selectedCount > 0 ? Color.green : Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                }
                .disabled(selectedCount == 0)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
            .onChange(of: tasks.count) { count in
                if count == 0 {
                    onDismiss()
                }
            }
        }
    }
}
