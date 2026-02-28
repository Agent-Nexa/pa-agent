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
    
    var body: some View {
        NavigationStack {
            List {
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
                            
                            Spacer()
                            
                            NavigationLink(destination: DashboardView(manager: trackingManager, category: category)) {
                                EmptyView()
                            }
                            .frame(width: 0)
                            .opacity(0)
                            
                            Button(action: {}) {
                                Image(systemName: "chart.bar")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .overlay(
                                NavigationLink(destination: DashboardView(manager: trackingManager, category: category)) {
                                    EmptyView()
                                }
                                .opacity(0)
                            )
                        }
                    }
                }
                .onDelete(perform: trackingManager.deleteCategory)
            }
            .navigationTitle("Tracking Categories")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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
        }
    }
}

struct TrackingRecordListView: View {
    @ObservedObject var manager: TrackingManager
    var category: TrackingCategory
    @State private var showingAddRecord = false
    @State private var newValueStr = ""
    @State private var newNote = ""
    
    var body: some View {
        List {
            let categoryRecords = manager.records(for: category.id)
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
            }
            .onDelete { offsets in
                manager.deleteRecord(at: offsets, for: category.id)
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
    }
}
