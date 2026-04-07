//
//  SharedInboxView.swift
//  pa-agent
//
//  Read-only history of items that were forwarded to Nexa via the Share
//  Extension (iMessage, WhatsApp, Telegram, Safari, etc.).
//  Processing happens automatically — when the app returns to the foreground
//  each pending item is injected into the chat and the Nexa agent responds
//  inline.
//

import SwiftUI

// MARK: - Source display helpers

private func sourceDisplayName(bundleID: String, fallback: String) -> String {
    let id = bundleID.lowercased()
    if id.contains("whatsapp")                      { return "WhatsApp" }
    if id.contains("mobilesms") || id.contains("messages") { return "Messages" }
    if id.contains("telegram")                      { return "Telegram" }
    if id.contains("instagram")                     { return "Instagram" }
    if id.contains("twitter") || id.contains("x-corp") { return "X / Twitter" }
    if id.contains("mobilesafari") || id.contains("safari") { return "Safari" }
    if id.contains("linkedin")                      { return "LinkedIn" }
    return fallback.isEmpty ? "Shared Content" : fallback
}

private func sourceIcon(bundleID: String) -> (name: String, color: Color) {
    let id = bundleID.lowercased()
    if id.contains("whatsapp")         { return ("message.fill",       .green) }
    if id.contains("mobilesms") || id.contains("messages") { return ("message.fill", .blue) }
    if id.contains("telegram")         { return ("paperplane.fill",    Color(red: 0.16, green: 0.56, blue: 0.84)) }
    if id.contains("instagram")        { return ("camera.fill",        Color(red: 0.83, green: 0.21, blue: 0.51)) }
    if id.contains("twitter") || id.contains("x-corp") { return ("text.bubble.fill", .primary) }
    if id.contains("mobilesafari") || id.contains("safari") { return ("safari.fill", .blue) }
    if id.contains("linkedin")         { return ("briefcase.fill",     Color(red: 0.01, green: 0.46, blue: 0.71)) }
    return ("square.and.arrow.down",    .secondary)
}

// MARK: - Main View

struct SharedInboxView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var items: [SharedItem] = []

    private var itemsFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.z.Nexa")?
            .appendingPathComponent("pendingSharedItems.json")
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .navigationTitle("Shared History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !items.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) { items = []; saveItems([]) } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if items.contains(where: { !$0.processed }) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.purple)
                        Text("Pending items will appear in chat when you return to Nexa.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            }
            .onAppear { loadItems() }
        }
    }

    // ── Empty state ────────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No Shared Items")
                .font(.title3.bold())
            Text("Share text, links or photos from iMessage, WhatsApp, or any app using the **Share → Nexa** option. They'll appear in chat automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Item list ──────────────────────────────────────────────────────

    private var itemList: some View {
        List {
            ForEach(items) { item in
                SharedItemRow(item: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteItem(item) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    // ── Data helpers ───────────────────────────────────────────────────

    private func loadItems() {
        guard let url = itemsFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.timestamp > $1.timestamp }
    }

    private func deleteItem(_ item: SharedItem) {
        items.removeAll { $0.id == item.id }
        saveItems(items)
    }

    private func saveItems(_ newItems: [SharedItem]) {
        guard let url = itemsFileURL,
              let data = try? JSONEncoder().encode(newItems) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Row

private struct SharedItemRow: View {
    let item: SharedItem

    private var icon: (name: String, color: Color) { sourceIcon(bundleID: item.sourceBundleID) }
    private var appName: String { sourceDisplayName(bundleID: item.sourceBundleID, fallback: item.sourceAppName) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(icon.color.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: icon.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(icon.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(appName)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(item.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch item.contentType {
                case "image":
                    Label("Image", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case "url":
                    Text(item.content)
                        .font(.footnote)
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                default:
                    Text(item.content.isEmpty ? "(no content)" : item.content)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if !item.userNote.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text").font(.caption2)
                        Text(item.userNote).font(.caption)
                    }
                    .foregroundStyle(.orange)
                }

                Label(item.processed ? "Sent to chat" : "Pending",
                      systemImage: item.processed ? "checkmark.circle.fill" : "clock.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(item.processed ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
