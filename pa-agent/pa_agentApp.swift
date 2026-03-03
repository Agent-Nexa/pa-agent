//
//  pa_agentApp.swift
//  pa-agent
//
//  Created by ZHEN YUAN on 12/2/2026.
//

import SwiftUI
import UserNotifications
import BackgroundTasks
#if canImport(Photos)
import Photos
#endif

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let receiptRefreshTaskIdentifier = "z.Nexa.receipt-refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundTasks()
        scheduleReceiptBackgroundRefresh()
        return true
    }
    
    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleReceiptBackgroundRefresh()
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.receiptRefreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleReceiptBackgroundRefresh(task: task)
        }
    }

    private func scheduleReceiptBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.receiptRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule receipt background refresh: \(error.localizedDescription)")
        }
    }

    private func handleReceiptBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleReceiptBackgroundRefresh()

        let worker = Task(priority: .background) { [weak self] in
            let foundCount = await self?.countNewReceiptAssets() ?? 0
            if foundCount > 0 {
                NotificationManager.shared.scheduleReceiptDetectedNotification(count: foundCount)
            }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            worker.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func countNewReceiptAssets() async -> Int {
        #if canImport(Photos)
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else { return 0 }

        guard let receiptsAlbum = findReceiptSmartAlbum() else { return 0 }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 30
        let assets = PHAsset.fetchAssets(in: receiptsAlbum, options: options)

        let seenIDs = Set(UserDefaults.standard.array(forKey: "seen_photo_receipt_asset_ids_v1") as? [String] ?? [])

        var count = 0
        assets.enumerateObjects { asset, _, _ in
            if !seenIDs.contains(asset.localIdentifier) {
                count += 1
            }
        }
        return count
        #else
        return 0
        #endif
    }

    private func findReceiptSmartAlbum() -> PHAssetCollection? {
        #if canImport(Photos)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        var bestMatch: PHAssetCollection?

        smartAlbums.enumerateObjects { collection, _, stop in
            let name = (collection.localizedTitle ?? "").lowercased()
            let hints = ["receipt", "receipts", "invoice", "invoices", "收据", "單據", "发票", "發票"]
            if hints.contains(where: { name.contains($0) }) {
                bestMatch = collection
                stop.pointee = true
            }
        }

        return bestMatch
        #else
        return nil
        #endif
    }
}

@main
struct nexaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                NotificationManager.shared.scheduleInactivityReminder(days: 3)
            }
        }
    }
}
