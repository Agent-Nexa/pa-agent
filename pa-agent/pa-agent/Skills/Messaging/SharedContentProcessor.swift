//
//  SharedContentProcessor.swift
//  pa-agent
//
//  Reads SharedItem payloads written by NexaShareExtension from the App Group
//  UserDefaults and hands them to the main chat pipeline so the Nexa agent can
//  respond inline – just like the user had typed the message themselves.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class SharedContentProcessor: ObservableObject {

    static let shared = SharedContentProcessor()
    private init() {}

    private let suiteName = "group.z.Nexa"
    private let udKey     = "pendingSharedItems"

    // Number of unprocessed items — drives badge in toolbar.
    @Published private(set) var pendingCount: Int = 0

    // ── Pending count ──────────────────────────────────────────────────

    func refreshPendingCount() {
        guard let ud = UserDefaults(suiteName: suiteName) else { return }
        pendingCount = loadItems(ud: ud).filter { !$0.processed }.count
    }

    // ── Drain ──────────────────────────────────────────────────────────

    /// Removes all unprocessed items from the queue, marks them processed, and
    /// returns them so the caller (ContentView) can inject them into the chat.
    func drainUnprocessed() -> [SharedItem] {
        guard let ud = UserDefaults(suiteName: suiteName) else { return [] }
        var items = loadItems(ud: ud)
        let unprocessed = items.filter { !$0.processed }
        guard !unprocessed.isEmpty else { return [] }

        // Mark every item as processed; keep last 50.
        for i in items.indices { items[i].processed = true }
        saveItems(Array(items.suffix(50)), ud: ud)
        pendingCount = 0
        return unprocessed
    }

    // ── Persistence helpers ────────────────────────────────────────────

    private func loadItems(ud: UserDefaults) -> [SharedItem] {
        guard let data = ud.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) else { return [] }
        return decoded
    }

    private func saveItems(_ items: [SharedItem], ud: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        ud.set(data, forKey: udKey)
    }
}
