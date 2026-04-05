import Foundation
import Combine

// MARK: - CreditManager
// Manages the user's credit balance.
// - New-user grant (200 credits) is determined exclusively by the server so it
//   cannot be double-claimed regardless of stale local UserDefaults state.
// - Local UserDefaults act only as an offline cache.
// - 1 credit = 1 AI token consumed.

@MainActor
final class CreditManager: ObservableObject {

    static let shared = CreditManager()

    // MARK: Constants

    static let newUserGrantAmount = 200
    private let creditsKey = "USER_CREDITS"

    /// Base URL of the PA-Agent backend.  Override via UserDefaults key
    /// "PA_AGENT_SERVER_URL" (e.g. in Settings) or change this default.
    private var serverBaseURL: String {
        UserDefaults.standard.string(forKey: "PA_AGENT_SERVER_URL")
            ?? "https://pa-agent-web-frontend.agreeableisland-6e08f0fa.australiaeast.azurecontainerapps.io"
    }

    // MARK: Published

    @Published private(set) var credits: Int = 0
    @Published private(set) var outOfCredits: Bool = false

    // MARK: Init

    private init() {
        credits = UserDefaults.standard.integer(forKey: creditsKey)
        // Don't gate the UI on the local cache being 0 on a fresh install.
        // initializeFromServer will set the real value once the server responds.
        outOfCredits = false
    }

    // MARK: - Server-Side Initialisation

    /// Calls `POST /api/credits/init` on the backend.
    /// The server is the single source of truth:
    ///   - First call for a userId → server grants 200 credits, returns is_new_user=true.
    ///   - Subsequent calls → server returns the existing balance, is_new_user=false.
    /// On success the local cache is updated from the server value.
    /// On network failure the existing local cache is kept so the app stays usable offline.
    func initializeFromServer(userId: String) async {
        guard !userId.isEmpty else { return }
        guard let url = URL(string: "\(serverBaseURL)/api/credits/init") else {
            print("[CreditManager] ⚠️  Invalid server URL — skipping server init")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = ["user_id": userId]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("[CreditManager] ⚠️  Server returned non-2xx for credits/init")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverCredits = json["credits"] as? Int {
                credits = serverCredits
                outOfCredits = credits <= 0
                persist()
                let isNew = json["is_new_user"] as? Bool ?? false
                print("[CreditManager] ✅ Credits synced from server: \(serverCredits) (new user: \(isNew))")
            }
        } catch {
            print("[CreditManager] ⚠️  Server unreachable (\(error.localizedDescription)) — using local cache (\(credits) credits)")
        }
    }

    // MARK: - Foreground Refresh

    /// Reads the live balance from `GET /api/credits/{user_id}` and updates the local cache.
    /// Use this on app-foreground to keep the display in sync with the DB without triggering a new-user grant.
    /// Falls back to `initializeFromServer` if the user has no DB record yet (404).
    func refreshFromServer(userId: String) async {
        guard !userId.isEmpty else { return }
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        guard let url = URL(string: "\(serverBaseURL)/api/credits/\(encoded)") else {
            print("[CreditManager] ⚠️  Invalid server URL — skipping foreground refresh")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverCredits = json["credits"] as? Int {
                credits = serverCredits
                outOfCredits = credits <= 0
                persist()
                print("[CreditManager] 🔄 Foreground refresh: \(serverCredits) credits from DB")
            } else if http.statusCode == 404 {
                // No DB record — initialise one (new-user grant logic lives on the server)
                print("[CreditManager] ℹ️  No DB record found — running initializeFromServer")
                await initializeFromServer(userId: userId)
            } else {
                print("[CreditManager] ⚠️  Foreground refresh returned \(http.statusCode) — keeping local cache")
            }
        } catch {
            print("[CreditManager] ⚠️  Foreground refresh failed (\(error.localizedDescription)) — keeping local cache")
        }
    }

    // MARK: - Deduction

    /// Deducts `amount` credits locally. Returns `true` if applied.
    /// Call `deductOnServer(userId:amount:)` afterwards if you want server-side reconciliation.
    @discardableResult
    func deduct(_ amount: Int) -> Bool {
        guard amount > 0 else { return true }
        guard credits >= amount else {
            outOfCredits = true
            return false
        }
        credits -= amount
        outOfCredits = credits <= 0
        persist()
        return true
    }

    // MARK: - Server-Side Deduction

    /// Deducts `amount` credits on the server, keeping the local cache in sync
    /// with the authoritative server balance on success.
    /// Fire-and-forget safe — on network failure the optimistic local deduction is preserved.
    func deductOnServer(userId: String, amount: Int) async {
        guard !userId.isEmpty, amount > 0 else { return }
        guard let url = URL(string: "\(serverBaseURL)/api/credits/deduct") else {
            print("[CreditManager] ⚠️  Invalid server URL — skipping server deduct")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = ["user_id": userId, "amount": amount]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverCredits = json["credits"] as? Int {
                // Sync to the authoritative server balance
                credits = serverCredits
                outOfCredits = credits <= 0
                persist()
                print("[CreditManager] ✅ Server deduct applied: \(serverCredits) credits remaining")
            } else if http.statusCode == 402 {
                // Server says insufficient credits — mark as out of credits
                credits = 0
                outOfCredits = true
                persist()
                print("[CreditManager] ⚠️  Server returned 402 — out of credits")
            } else {
                print("[CreditManager] ⚠️  Server deduct returned \(http.statusCode) — keeping local balance")
            }
        } catch {
            print("[CreditManager] ⚠️  Server deduct failed (\(error.localizedDescription)) — keeping local balance")
        }
    }

    // MARK: - Server-Side Top-Up

    /// Reconciles the credit balance against logged token usage.
    /// Closes the gap between tokens consumed (in tb_tokenTransactions) and
    /// credits actually deducted (TotalCreditsDeducted in tb_CreditManager).
    /// Safe to call on every sign-in — no-op when already in sync.
    func reconcileFromServer(userId: String) async {
        guard !userId.isEmpty else { return }
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        guard let url = URL(string: "\(serverBaseURL)/api/credits/reconcile/\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverCredits = json["credits"] as? Int {
                let wasReconciled = json["reconciled"] as? Bool ?? false
                let deficit = json["deficit"] as? Int ?? 0
                credits = serverCredits
                outOfCredits = credits <= 0
                persist()
                if wasReconciled {
                    print("[CreditManager] ⚙️ Reconciled: deducted \(deficit) missing credits. New balance: \(serverCredits)")
                } else {
                    print("[CreditManager] ✅ Balance already in sync: \(serverCredits) credits")
                }
            } else {
                print("[CreditManager] ⚠️  Reconcile returned \(http.statusCode)")
            }
        } catch {
            print("[CreditManager] ⚠️  Reconcile failed (\(error.localizedDescription))")
        }
    }

    /// Adds `amount` credits on the server (called after a successful IAP transaction).
    /// Updates the local balance from the server's authoritative response.
    func addOnServer(userId: String, amount: Int) async {
        guard !userId.isEmpty, amount > 0 else { return }
        guard let url = URL(string: "\(serverBaseURL)/api/credits/add") else {
            print("[CreditManager] ⚠️  Invalid server URL — skipping server add")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = ["user_id": userId, "amount": amount]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverCredits = json["credits"] as? Int {
                credits = serverCredits
                outOfCredits = credits <= 0
                persist()
                print("[CreditManager] ✅ Credits topped up. New balance: \(serverCredits)")
            } else {
                print("[CreditManager] ⚠️  Server add returned \(http.statusCode)")
            }
        } catch {
            print("[CreditManager] ⚠️  Server add failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Reconciliation

    /// Reconcile an earlier local estimate with the actual token amount used.
    func reconcile(estimated: Int, actual: Int) {
        let delta = actual - estimated
        if delta > 0 {
            credits = max(0, credits - delta)
            outOfCredits = credits <= 0
            persist()
        } else if delta < 0 {
            credits += abs(delta)
            outOfCredits = false
            persist()
        }
    }

    // MARK: - Helpers

    var displayText: String {
        credits == 1 ? "1 credit" : "\(credits) credits"
    }

    private func persist() {
        UserDefaults.standard.set(credits, forKey: creditsKey)
    }
}

