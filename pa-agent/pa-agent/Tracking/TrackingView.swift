//
//  TrackingView.swift
//  pa-agent
//
//  Created by ZHEN YUAN on 28/2/2026.
//

import SwiftUI

struct TrackingCategoriesView: View {
    @ObservedObject var trackingManager: TrackingManager
    @State private var showingAddCategory = false
    @State private var newCategoryName = ""
    @State private var newCategoryUnit = ""
    
    @State private var showingEditCategory = false
    @State private var categoryToEdit: TrackingCategory?
    
    var body: some View {
        NavigationStack {
            List {
                if !trackingManager.categories.isEmpty {
                    Section {
                        ForEach(trackingManager.categories) { category in
                            NavigationLink(destination: TrackingRecordListView(manager: trackingManager, category: category)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(category.name)
                                            .font(.headline)
                                        if let unit = category.unit, !unit.isEmpty {
                                            Text("Unit: \(unit)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    categoryToEdit = category
                                    newCategoryName = category.name
                                    newCategoryUnit = category.unit ?? ""
                                    showingEditCategory = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    if let index = trackingManager.categories.firstIndex(where: { $0.id == category.id }) {
                                        trackingManager.deleteCategory(at: IndexSet(integer: index))
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Swipe left-to-right to Edit, right-to-left to Delete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(nil)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Tracking Categories")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink(destination: DashboardView(manager: trackingManager)) {
                        Image(systemName: "chart.bar")
                    }
                    Button(action: { showingAddCategory = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Add Tracking Category", isPresented: $showingAddCategory) {
                TextField("Category Name (e.g., Spending, Fitness)", text: $newCategoryName)
                TextField("Unit (e.g., $, kcal)", text: $newCategoryUnit)
                Button("Add") {
                    let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let unit = newCategoryUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        trackingManager.addCategory(name: name, unit: unit.isEmpty ? nil : unit)
                    }
                    newCategoryName = ""
                    newCategoryUnit = ""
                }
                Button("Cancel", role: .cancel) {
                    newCategoryName = ""
                    newCategoryUnit = ""
                }
            }
            .alert("Edit Tracking Category", isPresented: $showingEditCategory) {
                TextField("Category Name", text: $newCategoryName)
                TextField("Unit", text: $newCategoryUnit)
                Button("Save") {
                    if let category = categoryToEdit {
                        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let unit = newCategoryUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            trackingManager.updateCategory(id: category.id, name: name, unit: unit.isEmpty ? nil : unit)
                        }
                    }
                    newCategoryName = ""
                    newCategoryUnit = ""
                    categoryToEdit = nil
                }
                Button("Cancel", role: .cancel) {
                    newCategoryName = ""
                    newCategoryUnit = ""
                    categoryToEdit = nil
                }
            }
        }
    }
}

struct TrackingRecordListView: View {
    @ObservedObject var manager: TrackingManager
    var category: TrackingCategory
    @State private var showingAddRecord = false
    @State private var newValueStr = ""
    @State private var newNote = ""
    
    @State private var showingEditRecord = false
    @State private var recordToEdit: TrackingRecord?
    
    var body: some View {
        let categoryRecords = manager.records(for: category.id)
        
        List {
            if !categoryRecords.isEmpty {
                Section {
                    ForEach(categoryRecords) { record in
                        VStack(alignment: .leading) {
                            HStack {
                                Text("\(record.value, specifier: "%.2f")")
                                    .font(.headline)
                                if let unit = category.unit {
                                    Text(unit)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(record.date, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let note = record.note, !note.isEmpty {
                                Text(note)
                                    .font(.subheadline)
                            }
                            if let rawText = record.rawText, !rawText.isEmpty {
                                Text("Source: \"\(rawText)\"")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .italic()
                            }
                        }
                        .contentShape(Rectangle())
                        .swipeActions(edge: .leading) {
                            Button {
                                recordToEdit = record
                                newValueStr = String(format: "%.2f", record.value)
                                newNote = record.note ?? ""
                                showingEditRecord = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let index = categoryRecords.firstIndex(where: { $0.id == record.id }) {
                                    manager.deleteRecord(at: IndexSet(integer: index), for: category.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Swipe left-to-right to Edit, right-to-left to Delete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                        .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle(category.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingAddRecord = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Add Record", isPresented: $showingAddRecord) {
            TextField("Value", text: $newValueStr)
            TextField("Note (optional)", text: $newNote)
            Button("Add") {
                if let value = Double(newValueStr) {
                    manager.addRecord(categoryId: category.id, value: value, note: newNote.isEmpty ? nil : newNote)
                }
                newValueStr = ""
                newNote = ""
            }
            Button("Cancel", role: .cancel) {
                newValueStr = ""
                newNote = ""
            }
        }
        .alert("Edit Record", isPresented: $showingEditRecord) {
            TextField("Value", text: $newValueStr)
            TextField("Note (optional)", text: $newNote)
            Button("Save") {
                if let record = recordToEdit, let value = Double(newValueStr) {
                    manager.updateRecord(id: record.id, value: value, note: newNote.isEmpty ? nil : newNote, date: record.date)
                }
                newValueStr = ""
                newNote = ""
                recordToEdit = nil
            }
            Button("Cancel", role: .cancel) {
                newValueStr = ""
                newNote = ""
                recordToEdit = nil
            }
        }
    }
}
