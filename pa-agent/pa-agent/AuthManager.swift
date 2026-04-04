import Foundation
import Combine
import MSAL

// MARK: - Configuration
// Replace these values with your Azure Entra External ID app registration details.
// Authority format for External ID (CIAM): https://<tenantSubdomain>.ciamlogin.com/<tenantId>
private enum MSALConfig {
    static let clientId    = "93317bf1-efab-46e2-8eb6-c1d113793179"          // App registration Client ID (GUID)
    static let tenantId    = "223379a7-0520-4876-98f1-befbc7bfb9a8"          // External ID tenant directory ID (GUID)
    static let tenantName  = "zyb2c"                   // subdomain only — e.g. "zyb2c" from zyb2c.ciamlogin.com
    static let authority   = "https://\(tenantName).ciamlogin.com/\(tenantId)"
    static let redirectUri = "msauth.z.Nexa://auth"
    // openid, profile, offline_access are reserved — MSAL adds them automatically.
    // email is requested explicitly to ensure the claim is returned in the ID token.
    static let scopes      = ["email"]
}

// MARK: - AuthManager

@MainActor
final class AuthManager: ObservableObject {

    // MARK: Published state

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var displayName: String = ""
    @Published private(set) var email: String = ""
    @Published private(set) var userId: String = ""        // Entra object ID (used for credit grant deduplication)
    @Published private(set) var accessToken: String = ""
    @Published private(set) var isLoading: Bool = false    // true while silent sign-in is resolving on launch
    @Published private(set) var authError: String?

    // MARK: Private

    private var msalApp: MSALPublicClientApplication?

    // MARK: Init

    init() {
        configure()
        Task { await silentSignIn() }
    }

    // MARK: - Setup

    private func configure() {
        guard MSALConfig.clientId != "YOUR_CLIENT_ID" else {
            print("[AuthManager] ⚠️  MSALConfig placeholders not yet replaced. Skipping MSAL init.")
            authError = "Placeholders not replaced in AuthManager.swift"
            return
        }

        print("[AuthManager] Configuring with authority: \(MSALConfig.authority)")

        guard let authorityURL = URL(string: MSALConfig.authority) else {
            let msg = "Could not form URL from: \(MSALConfig.authority)"
            print("[AuthManager] ❌ \(msg)")
            authError = msg
            return
        }

        do {
            let authority = try MSALCIAMAuthority(url: authorityURL)
            let config = MSALPublicClientApplicationConfig(
                clientId: MSALConfig.clientId,
                redirectUri: MSALConfig.redirectUri,
                authority: authority
            )
            msalApp = try MSALPublicClientApplication(configuration: config)
            print("[AuthManager] ✅ MSALPublicClientApplication configured successfully")
        } catch {
            let msg = "MSAL init failed: \(error.localizedDescription)"
            print("[AuthManager] ❌ \(msg)\nFull error: \(error)")
            authError = msg
        }
    }

    // MARK: - Interactive Sign-In

    func signIn(presenting viewController: UIViewController) {
        guard let msalApp else {
            authError = "Auth not configured. Set Client ID and Tenant ID in AuthManager.swift."
            return
        }

        let webParameters = MSALWebviewParameters(authPresentationViewController: viewController)
        let interactiveParameters = MSALInteractiveTokenParameters(scopes: MSALConfig.scopes, webviewParameters: webParameters)

        isLoading = true
        authError = nil

        msalApp.acquireToken(with: interactiveParameters) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false
                if let error = error as NSError? {
                    let details = """
                    [AuthManager] ❌ acquireToken failed
                      localizedDescription: \(error.localizedDescription)
                      domain: \(error.domain)
                      code: \(error.code)
                      userInfo: \(error.userInfo)
                    """
                    print(details)
                    self.authError = "[\(error.domain) \(error.code)] \(error.userInfo[MSALErrorDescriptionKey] as? String ?? error.localizedDescription)"
                    return
                }
                guard let result else { return }
                self.applyResult(result)
            }
        }
    }

    // MARK: - Silent Sign-In (restore session on launch)

    func silentSignIn() async {
        guard let msalApp else {
            isLoading = false
            return
        }

        // allAccounts() is synchronous in MSAL iOS
        guard let account = try? msalApp.allAccounts().first else {
            isLoading = false
            return
        }

        guard let authorityURL = URL(string: MSALConfig.authority),
              let authority = try? MSALCIAMAuthority(url: authorityURL) else {
            isLoading = false
            return
        }

        let silentParameters = MSALSilentTokenParameters(scopes: MSALConfig.scopes, account: account)
        silentParameters.authority = authority

        // MSAL uses callbacks, not async/await — wrap with a continuation
        let result: MSALResult? = await withCheckedContinuation { continuation in
            msalApp.acquireTokenSilent(with: silentParameters) { result, error in
                if let error {
                    print("[AuthManager] Silent sign-in failed (expected on first launch): \(error.localizedDescription)")
                }
                continuation.resume(returning: result)
            }
        }

        isLoading = false
        if let result { applyResult(result) }
        // If nil, the cached token is expired — LoginView will show
    }

    // MARK: - Sign Out

    func signOut() {
        guard let msalApp else { return }

        do {
            let accounts = try msalApp.allAccounts()
            for account in accounts {
                try msalApp.remove(account)
            }
        } catch {
            print("[AuthManager] Sign-out error: \(error)")
        }

        isSignedIn = false
        displayName = ""
        email = ""
        userId = ""
        accessToken = ""
        authError = nil
    }

    // MARK: - Handle Redirect URL (called from AppDelegate)

    static func handleMSALResponse(_ url: URL) -> Bool {
        return MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
    }

    // MARK: - Helpers

    private func applyResult(_ result: MSALResult) {
        isSignedIn  = true
        accessToken = result.accessToken

        let account = result.account
        displayName = extractClaim("name", from: result.idToken)
                      ?? account.username
                      ?? ""
        email       = extractClaim("email", from: result.idToken)
                      ?? extractClaim("preferred_username", from: result.idToken)
                      ?? account.username
                      ?? ""
        userId      = account.identifier ?? ""
    }

    private func extractClaim(_ claim: String, from idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        // Pad to 4-byte boundary
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[claim] as? String
        else { return nil }
        return value
    }
}
