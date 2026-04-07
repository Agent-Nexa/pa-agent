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

// Notification posted on the main NotificationCenter when any extension writes a
// new SharedItem to the App Group. ContentView observes this to inject content
// immediately, even when the app is already in the foreground.
extension Notification.Name {
    static let nexaSharedItemArrived = Notification.Name("group.z.Nexa.sharedItemArrived")
}

@MainActor
final class SharedContentProcessor: ObservableObject {

    static let shared = SharedContentProcessor()
    private init() {}

    private let appGroupID = "group.z.Nexa"

    // File in the shared App Group container — visible to all processes immediately,
    // unlike UserDefaults which has an in-process cache that synchronize() cannot clear.
    private var itemsFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("pendingSharedItems.json")
    }

    // Number of unprocessed items — drives badge in toolbar.
    @Published private(set) var pendingCount: Int = 0

    // Guard against registering the Darwin observer more than once.
    private var darwinListenerRegistered = false

    // ── Darwin → NotificationCenter bridge ────────────────────────────

    /// Call once at app start. Registers a Darwin notification observer that
    /// bridges to NotificationCenter.default so SwiftUI views can observe it.
    /// Safe to call multiple times — only registers once.
    func startListeningForExtensionEvents() {
        guard !darwinListenerRegistered else { return }
        darwinListenerRegistered = true
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            darwinCenter,
            nil,
            { _, _, _, _, _ in
                // C callback — no captures allowed. Bridge via NotificationCenter.
                NotificationCenter.default.post(name: .nexaSharedItemArrived, object: nil)
            },
            "group.z.Nexa.sharedItemAdded" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // ── Pending count ──────────────────────────────────────────────────

    func refreshPendingCount() {
        pendingCount = loadItems().filter { !$0.processed }.count
    }

    // ── Drain ──────────────────────────────────────────────────────────

    /// Removes all unprocessed items from the queue, marks them processed, and
    /// returns them so the caller (ContentView) can inject them into the chat.
    func drainUnprocessed() -> [SharedItem] {
        var items = loadItems()
        let unprocessed = items.filter { !$0.processed }
        guard !unprocessed.isEmpty else { return [] }

        // Mark every item as processed; keep last 50.
        for i in items.indices { items[i].processed = true }
        saveItems(Array(items.suffix(50)))
        pendingCount = 0
        return unprocessed
    }

    // ── File-based persistence (cross-process safe) ────────────────────

    private func loadItems() -> [SharedItem] {
        guard let url = itemsFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) else { return [] }
        return decoded
    }

    private func saveItems(_ items: [SharedItem]) {
        guard let url = itemsFileURL,
              let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
