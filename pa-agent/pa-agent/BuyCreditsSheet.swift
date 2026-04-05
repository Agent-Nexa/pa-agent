import SwiftUI

// MARK: - BuyCreditsSheet

struct BuyCreditsSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var creditManager: CreditManager
    @StateObject private var purchaseManager = CreditPurchaseManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Current balance banner ──────────────────────────────
                VStack(spacing: 4) {
                    Text("Your Balance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(creditManager.displayText)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(creditManager.credits > 50 ? .green
                                          : creditManager.credits > 10 ? .orange : .red)
                }
                .padding(.vertical, 24)

                Divider()

                // ── Package list ────────────────────────────────────────
                List {
                    Section {
                        ForEach(purchaseManager.packages) { pkg in
                            PackageRow(
                                pkg: pkg,
                                price: purchaseManager.displayPrice(for: pkg),
                                isPurchasing: purchaseManager.isPurchasing
                            ) {
                                Task {
                                    await purchaseManager.purchase(
                                        package: pkg,
                                        userId: authManager.email
                                    )
                                }
                            }
                        }
                    } header: {
                        Text("Choose a pack")
                    } footer: {
                        Text("1 credit = 5,000 AI tokens. Purchases are non-refundable. Credits do not expire.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if purchaseManager.isLoadingProducts {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Loading packages…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !purchaseManager.statusMessage.isEmpty {
                        Section {
                            Text(purchaseManager.statusMessage)
                                .font(.footnote)
                                .foregroundStyle(
                                    purchaseManager.statusMessage.lowercased().contains("failed")
                                    || purchaseManager.statusMessage.lowercased().contains("unavailable")
                                        ? .red : .secondary
                                )
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Buy Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if purchaseManager.storeProducts.isEmpty {
                    await purchaseManager.loadProducts()
                }
            }
        }
    }
}

// MARK: - PackageRow

private struct PackageRow: View {
    let pkg: CreditPackage
    let price: String
    let isPurchasing: Bool
    let onBuy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(pkg.credits >= 500 ? Color.purple.opacity(0.14) : Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: pkg.credits >= 500 ? "star.fill" : "sparkles")
                    .foregroundStyle(pkg.credits >= 500 ? .purple : .blue)
            }

            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pkg.credits) Credits")
                    .font(.subheadline.weight(.semibold))
                Text(creditDescription(for: pkg.credits))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Price + buy button
            VStack(alignment: .trailing, spacing: 4) {
                Text(price)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Button(action: onBuy) {
                    if isPurchasing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Buy")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .disabled(isPurchasing)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func creditDescription(for credits: Int) -> String {
        let tokens = credits * 5000
        let millions = Double(tokens) / 1_000_000
        if millions >= 1 {
            let fmt = String(format: "%.1f", millions)
            return "≈ \(fmt)M AI tokens"
        }
        return "≈ \(tokens / 1000)K AI tokens"
    }
}

// MARK: - Preview

#Preview {
    BuyCreditsSheet()
        .environmentObject(AuthManager())
        .environmentObject(CreditManager.shared)
}
