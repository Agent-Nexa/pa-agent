import Foundation
import StoreKit
import Combine

// MARK: - CreditPackage
// Describes a credit top-up product available for purchase.

struct CreditPackage: Identifiable {
    let productID: String
    let credits: Int
    var id: String { productID }
}

// MARK: - CreditPurchaseManager

@MainActor
final class CreditPurchaseManager: ObservableObject {

    static let shared = CreditPurchaseManager()

    // MARK: - Available packages
    // Create matching consumable IAPs in App Store Connect with these product IDs.

    let packages: [CreditPackage] = [
        CreditPackage(productID: "com.nexa.credits.200", credits: 200),
        CreditPackage(productID: "com.nexa.credits.500", credits: 500),
    ]

    // MARK: - Published state

    @Published private(set) var storeProducts: [Product] = []
    @Published var isLoadingProducts: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var statusMessage: String = ""

    private var updatesTask: Task<Void, Never>?

    private init() {
        #if !DEBUG
        updatesTask = observeTransactionUpdates()
        Task { await loadProducts() }
        #endif
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - StoreKit product loading

    func loadProducts() async {
        #if DEBUG
        return
        #else
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let productIDs = packages.map(\.productID)
            let loaded = try await Product.products(for: productIDs)
            // Keep ordering consistent with packages array
            storeProducts = packages.compactMap { pkg in
                loaded.first(where: { $0.id == pkg.productID })
            }
            if loaded.isEmpty {
                statusMessage = "Credit packages are currently unavailable."
            }
        } catch {
            statusMessage = "Could not load credit packages: \(error.localizedDescription)"
        }
        #endif
    }

    // MARK: - Purchase

    /// Purchases a credit package and tops up the server balance.
    /// In DEBUG mode it bypasses StoreKit and directly tops up via the backend.
    func purchase(package pkg: CreditPackage, userId: String) async {
        guard !userId.isEmpty else {
            statusMessage = "Sign in required to purchase credits."
            return
        }

        #if DEBUG
        // Dev shortcut: add credits directly so the flow can be tested without StoreKit.
        statusMessage = "Debug mode: adding \(pkg.credits) credits…"
        await CreditManager.shared.addOnServer(userId: userId, amount: pkg.credits)
        statusMessage = "Debug: \(pkg.credits) credits added."
        return
        #else

        // TestFlight: same bypass
        if Bundle.main.isTestFlight {
            statusMessage = "TestFlight: adding \(pkg.credits) credits…"
            await CreditManager.shared.addOnServer(userId: userId, amount: pkg.credits)
            statusMessage = "TestFlight: \(pkg.credits) credits added."
            return
        }

        guard let product = storeProducts.first(where: { $0.id == pkg.productID }) else {
            statusMessage = "This package is currently unavailable."
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
                    // Server-side top-up — single source of truth for balance
                    await CreditManager.shared.addOnServer(userId: userId, amount: pkg.credits)
                    statusMessage = "\(pkg.credits) credits added successfully!"
                case .unverified:
                    statusMessage = "Purchase couldn't be verified. Please contact support."
                }
            case .userCancelled:
                statusMessage = ""
            case .pending:
                statusMessage = "Purchase is pending approval."
            @unknown default:
                statusMessage = "Unknown purchase result."
            }
        } catch {
            let message = (error as NSError).localizedDescription
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || message == "The operation couldn't be completed." {
                statusMessage = "Purchase failed. Please sign in to App Store and try again."
            } else {
                statusMessage = "Purchase failed: \(message)"
            }
        }
        #endif
    }

    // MARK: - Transaction updates (handles pending & interrupted purchases)

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                // Only handle our credit product IDs
                let productIDs = self.packages.map(\.productID)
                guard productIDs.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }

                let credits = self.packages.first(where: { $0.productID == transaction.productID })?.credits ?? 0
                if credits > 0 {
                    // We don't know the userId here from the transaction alone.
                    // Rely on the in-app purchase flow to call addOnServer; this
                    // handler just finishes orphaned transactions that weren't consumed.
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Display helpers

    /// Returns the StoreKit-formatted display price for a package, or a fallback string.
    func displayPrice(for pkg: CreditPackage) -> String {
        storeProducts.first(where: { $0.id == pkg.productID })?.displayPrice ?? "—"
    }
}
