import Foundation
import Combine

// MARK: - CreditManager
// Manages the user's credit balance.
// - New users receive 200 credits once after their first sign-in.
// - 1 credit = 1 AI token consumed.
// - Credits are stored locally in UserDefaults, keyed to the Entra user ID so
//   the grant cannot be claimed again even after sign-out/sign-in.

@MainActor
final class CreditManager: ObservableObject {

    static let shared = CreditManager()

    // MARK: Constants

    static let newUserGrantAmount = 200
    private let creditsKey         = "USER_CREDITS"
    private let grantedUserIdKey   = "CREDITS_GRANT_USER_ID"

    // MARK: Published

    @Published private(set) var credits: Int = 0
    @Published private(set) var outOfCredits: Bool = false

    // MARK: Init

    private init() {
        credits = UserDefaults.standard.integer(forKey: creditsKey)
        outOfCredits = credits <= 0
    }

    // MARK: - New-User Grant

    /// Call this after a successful sign-in with the Entra account identifier.
    /// The 200-credit grant is issued only once per `userId`.
    func grantNewUserCreditsIfNeeded(userId: String) {
        guard !userId.isEmpty else { return }
        let alreadyGrantedTo = UserDefaults.standard.string(forKey: grantedUserIdKey) ?? ""
        guard alreadyGrantedTo != userId else { return }   // already claimed

        credits += Self.newUserGrantAmount
        persist()
        UserDefaults.standard.set(userId, forKey: grantedUserIdKey)
        outOfCredits = credits <= 0
    }

    // MARK: - Deduction

    /// Deducts `amount` credits. Returns `true` if the deduction was applied,
    /// or `false` if there were not enough credits (deduction is not applied).
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

    /// Call this after actual token usage is known to reconcile an earlier estimate.
    /// Pass the actual token count. If actual > estimated, deducts the difference;
    /// if actual < estimated, refunds the over-deduction.
    func reconcile(estimated: Int, actual: Int) {
        let delta = actual - estimated
        if delta > 0 {
            // Used more than estimated — deduct the extra
            credits = max(0, credits - delta)
            outOfCredits = credits <= 0
            persist()
        } else if delta < 0 {
            // Used less than estimated — refund the difference
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
