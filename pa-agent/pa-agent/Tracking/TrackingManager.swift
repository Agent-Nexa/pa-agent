//
//  TrackingManager.swift
//  pa-agent
//
//  Created by ZHEN YUAN on 28/2/2026.
//

import Foundation
import Combine
import SwiftUI

class TrackingManager: ObservableObject {
    @Published var categories: [TrackingCategory] = []
    @Published var records: [TrackingRecord] = []
    
    private let categoriesKey = "tracking_categories"
    private let recordsKey = "tracking_records"
    
    init() {
        load()
    }
    
    func addCategory(name: String, unit: String?) {
        let category = TrackingCategory(name: name, unit: unit)
        categories.append(category)
        save()
    }
    
    func deleteCategory(at offsets: IndexSet) {
        let idsToDelete = offsets.map { categories[$0].id }
        categories.remove(atOffsets: offsets)
        records.removeAll { idsToDelete.contains($0.categoryId) }
        save()
    }
    
    func addRecord(categoryId: UUID, value: Double, note: String? = nil, rawText: String? = nil, date: Date = Date()) {
        let record = TrackingRecord(categoryId: categoryId, value: value, note: note, date: date, rawText: rawText)
        records.append(record)
        save()
    }
    
    func records(for categoryId: UUID) -> [TrackingRecord] {
        return records.filter { $0.categoryId == categoryId }.sorted { $0.date > $1.date }
    }
    
    func deleteRecord(at offsets: IndexSet, for categoryId: UUID) {
        let categoryRecords = records(for: categoryId)
        let idsToDelete = offsets.map { categoryRecords[$0].id }
        records.removeAll { idsToDelete.contains($0.id) }
        save()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(encoded, forKey: categoriesKey)
        }
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: recordsKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: categoriesKey),
           let decoded = try? JSONDecoder().decode([TrackingCategory].self, from: data) {
            categories = decoded
        }
        
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([TrackingRecord].self, from: data) {
            records = decoded
        }
    }
}
