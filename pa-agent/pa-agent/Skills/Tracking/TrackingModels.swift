//
//  TrackingCategory.swift
//  pa-agent
//
//  Created by ZHEN YUAN on 28/2/2026.
//

import Foundation

struct TrackingCategory: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String // e.g., "spending", "fitness"
    var unit: String? // e.g., "$", "calories", "km"
    var createdAt: Date = Date()
}

struct TrackingRecord: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var categoryId: UUID
    var value: Double
    var note: String?
    var date: Date = Date()
    var rawText: String?
}
