import Foundation
import StoreKit
import Combine

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var hasActiveSubscription: Bool
    @Published private(set) var products: [Product] = []
    @Published var isLoadingProducts: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var statusMessage: String = ""

    private let productIDs = ["com.paagent.subscription.monthly"]
    private let subscriptionKey = "HAS_ACTIVE_SUBSCRIPTION"
    private var updatesTask: Task<Void, Never>?

    private init() {
        hasActiveSubscription = UserDefaults.standard.bool(forKey: subscriptionKey)
        #if !DEBUG
        updatesTask = observeTransactionUpdates()
        Task {
            await loadProducts()
            await refreshSubscriptionStatus()
        }
        #endif
    }

    deinit {
        updatesTask?.cancel()
    }

    var primaryProduct: Product? {
        products.first
    }

    var displayStatus: String {
        hasActiveSubscription ? "Active" : "Not active"
    }

    func loadProducts() async {
        #if DEBUG
        return
        #else
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: productIDs)
            products = loaded.sorted { $0.displayName < $1.displayName }
            if loaded.isEmpty {
                statusMessage = "Subscription product not found."
            }
        } catch {
            statusMessage = "Unable to load subscription products."
        }
        #endif
    }

    func purchasePrimarySubscription() async {
        #if DEBUG
        statusMessage = "Debug mode bypasses subscription checks."
        return
        #else
        guard let product = primaryProduct else {
            statusMessage = "Subscription product unavailable."
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    statusMessage = "Subscription activated."
                    await refreshSubscriptionStatus()
                case .unverified:
                    statusMessage = "Purchase couldn't be verified."
                }
            case .userCancelled:
                statusMessage = "Purchase cancelled."
            case .pending:
                statusMessage = "Purchase is pending approval."
            @unknown default:
                statusMessage = "Unknown purchase result."
            }
        } catch {
            let message = (error as NSError).localizedDescription
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message == "The operation couldn’t be completed." {
                statusMessage = "Purchase failed. Please sign in to App Store and try again."
            } else {
                statusMessage = "Purchase failed: \(message)"
            }
        }
        #endif
    }

    func restorePurchases() async {
        #if DEBUG
        statusMessage = "Debug mode bypasses subscription checks."
        return
        #else
        do {
            try await AppStore.sync()
            await refreshSubscriptionStatus()
            statusMessage = hasActiveSubscription ? "Subscription restored." : "No active subscription found."
        } catch {
            let message = (error as NSError).localizedDescription
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message == "The operation couldn’t be completed." {
                statusMessage = "Restore failed. Please sign in to App Store and try again."
            } else {
                statusMessage = "Restore failed: \(message)"
            }
        }
        #endif
    }

    func refreshSubscriptionStatus() async {
        #if DEBUG
        return
        #else
        var active = false

        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard productIDs.contains(transaction.productID) else { continue }
            if transaction.revocationDate != nil { continue }
            if let expirationDate = transaction.expirationDate, expirationDate <= Date() { continue }
            active = true
            break
        }

        hasActiveSubscription = active
        UserDefaults.standard.set(active, forKey: subscriptionKey)
        #endif
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            guard let self else { return }
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await self.refreshSubscriptionStatus()
            }
        }
    }
}
