import Foundation
import Combine
import MSAL
import LocalAuthentication

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
    // Pass empty array so MSAL uses the defaults; avoids scope rejection on CIAM tenants.
    static let scopes: [String] = []
}

// MARK: - AuthManager

@MainActor
final class AuthManager: ObservableObject {

    // MARK: Published state

    @Published private(set) var isSignedIn: Bool        = false
    @Published private(set) var displayName: String      = ""
    @Published private(set) var email: String            = ""
    @Published private(set) var userId: String           = ""
    @Published private(set) var accessToken: String      = ""
    @Published private(set) var isLoading: Bool          = true  // true until silentSignIn resolves
    @Published private(set) var authError: String?
    /// True when a cached account exists and biometric verification is pending.
    @Published private(set) var requiresBiometric: Bool        = false
    /// True after first sign-in when device has biometrics and user hasn't been asked yet.
    @Published private(set) var shouldPromptBiometricSetup: Bool = false

    private let biometricSetupAskedKey = "BIOMETRIC_SETUP_ASKED"
    /// UserDefaults key — set after every successful sign-in, cleared on sign-out.
    /// Used to drive the biometric relaunch gate independently of MSAL's Keychain cache.
    private let lastUserIdKey       = "LAST_SIGNED_IN_USER_ID"
    private let lastDisplayNameKey  = "LAST_SIGNED_IN_DISPLAY_NAME"
    private let lastEmailKey        = "LAST_SIGNED_IN_EMAIL"
    /// Whether the device supports and has biometrics enrolled.
    var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

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
            isLoading = false
            return
        }

        print("[AuthManager] Configuring with authority: \(MSALConfig.authority)")

        guard let authorityURL = URL(string: MSALConfig.authority) else {
            let msg = "Could not form URL from: \(MSALConfig.authority)"
            print("[AuthManager] ❌ \(msg)")
            authError = msg
            isLoading = false
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
            isLoading = false
        }
    }

    // MARK: - Interactive Sign-In

    func signIn(presenting viewController: UIViewController) {
        acquireToken(presenting: viewController, prompt: .login)
    }

    func signUp(presenting viewController: UIViewController) {
        acquireToken(presenting: viewController, prompt: .create)
    }

    private func acquireToken(presenting viewController: UIViewController, prompt: MSALPromptType) {
        guard let msalApp else {
            authError = "Auth not configured. Set Client ID and Tenant ID in AuthManager.swift."
            return
        }

        let webParameters = MSALWebviewParameters(authPresentationViewController: viewController)
        let interactiveParameters = MSALInteractiveTokenParameters(scopes: MSALConfig.scopes, webviewParameters: webParameters)
        interactiveParameters.promptType = prompt

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
        // Check UserDefaults for a previously signed-in user.
        // This is more reliable than querying MSAL's allAccounts() on CIAM tenants
        // where Keychain reads silently fail between cold launches.
        let savedUserId = UserDefaults.standard.string(forKey: lastUserIdKey)
        print("[AuthManager] silentSignIn: savedUserId=\(savedUserId ?? "nil")")

        guard savedUserId != nil else {
            print("[AuthManager] silentSignIn: no saved user — showing LoginView")
            isLoading = false
            return
        }

        // A user was previously signed in — gate with Face ID / Touch ID if available.
        let ctx = LAContext()
        var biometricError: NSError?
        let canUseBiometrics = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
        print("[AuthManager] silentSignIn: canUseBiometrics=\(canUseBiometrics) biometryType=\(ctx.biometryType.rawValue)")

        if canUseBiometrics {
            isLoading = false
            requiresBiometric = true
            print("[AuthManager] silentSignIn: requiresBiometric=true — BiometricLockView shown")
            return
        }

        // No biometrics on device — try silent MSAL token refresh, fall back to UserDefaults profile.
        guard let msalApp else {
            restoreFromSavedProfile()
            isLoading = false
            return
        }

        let msalAccount = (try? msalApp.allAccounts())?.first
        if let account = msalAccount {
            await performSilentTokenRefresh(account: account)
        } else {
            isLoading = false
        }
        if !isSignedIn {
            restoreFromSavedProfile()
        }
    }

    // MARK: - Biometric Sign-In

    func biometricSignIn() async {
        let msalAccount = (try? msalApp?.allAccounts())?.first
        print("[AuthManager] biometricSignIn: msalAccount=\(msalAccount?.username ?? "nil")")
        let ctx = LAContext()
        let reason = "Verify your identity to access Nexa"

        let success = await withCheckedContinuation { continuation in
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: reason) { success, error in
                print("[AuthManager] biometricSignIn: result=\(success) error=\(error?.localizedDescription ?? "none")")
                continuation.resume(returning: success)
            }
        }

        guard success else {
            // Biometric failed — keep requiresBiometric true so user can retry
            authError = "Biometric verification failed. Try again."
            return
        }

        authError = nil
        requiresBiometric = false

        if let account = msalAccount {
            await performSilentTokenRefresh(account: account)
        }
        // Regardless of whether MSAL silent refresh worked, if not signed in yet
        // restore from UserDefaults (biometric already verified identity).
        if !isSignedIn {
            restoreFromSavedProfile()
        }
    }

    /// Dismiss biometric lock and fall back to full sign-in
    func cancelBiometricAndSignOut() {
        requiresBiometric = false
        signOut()
    }

    private func performSilentTokenRefresh(account: MSALAccount) async {
        guard let msalApp else { return }

        guard let authorityURL = URL(string: MSALConfig.authority),
              let authority = try? MSALCIAMAuthority(url: authorityURL) else {
            isLoading = false
            return
        }

        // CIAM silent refresh: pass the actual OIDC scopes MSAL expanded during interactive login.
        // Using empty scopes [] fails because MSAL can't match the cached token entry.
        let silentScopes = ["openid", "profile", "offline_access"]
        let silentParameters = MSALSilentTokenParameters(scopes: silentScopes, account: account)
        silentParameters.authority = authority

        let result: MSALResult? = await withCheckedContinuation { continuation in
            msalApp.acquireTokenSilent(with: silentParameters) { result, error in
                if let error {
                    print("[AuthManager] Silent token refresh failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: result)
            }
        }

        isLoading = false
        if let result {
            applyResult(result)
        } else {
            // Silent refresh failed (expired token or CIAM issue).
            // Do NOT remove the cached MSAL account — preserve it so Face ID
            // can gate the next launch. Just clear in-memory state so LoginView
            // is shown and the user can interactively re-authenticate once.
            print("[AuthManager] Silent refresh failed — clearing in-memory state but keeping MSAL account in cache")
            isSignedIn        = false
            requiresBiometric = false
            displayName       = ""
            email             = ""
            userId            = ""
            accessToken       = ""
            authError         = nil
        }
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

        isSignedIn        = false
        requiresBiometric = false
        displayName       = ""
        email             = ""
        userId            = ""
        accessToken       = ""
        authError         = nil
        // Clear persisted login state so next launch goes straight to LoginView.
        UserDefaults.standard.removeObject(forKey: lastUserIdKey)
        UserDefaults.standard.removeObject(forKey: lastDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: lastEmailKey)
        UserDefaults.standard.removeObject(forKey: biometricSetupAskedKey)
    }

    // MARK: - Handle Redirect URL (called from AppDelegate)

    static func handleMSALResponse(_ url: URL) -> Bool {
        return MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
    }

    // MARK: - Helpers

    /// Populate state from a cached account when silent token refresh is unavailable.
    /// The user authenticated via biometrics so identity is verified; access token is empty
    /// and will be refreshed on the next API call.
    private func applyAccountAsFallback(_ account: MSALAccount) {
        isSignedIn  = true
        displayName = account.username ?? ""
        email       = account.username ?? ""
        userId      = account.identifier ?? ""
        accessToken = ""
        print("[AuthManager] Biometric fallback: signed in from cached account (no fresh token)")
    }

    /// Restore profile from UserDefaults when MSAL Keychain returns no account.
    private func restoreFromSavedProfile() {
        let savedId   = UserDefaults.standard.string(forKey: lastUserIdKey) ?? ""
        let savedName = UserDefaults.standard.string(forKey: lastDisplayNameKey) ?? ""
        let savedEmail = UserDefaults.standard.string(forKey: lastEmailKey) ?? ""
        guard !savedId.isEmpty else { return }
        isSignedIn   = true
        userId       = savedId
        displayName  = savedName
        email        = savedEmail
        accessToken  = ""   // will be refreshed on next API call
        print("[AuthManager] Restored profile from UserDefaults: \(savedEmail)")
    }

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

        // Persist profile to UserDefaults so the biometric relaunch gate works
        // even if MSAL's Keychain cache is not readable on the next launch.
        UserDefaults.standard.set(userId,      forKey: lastUserIdKey)
        UserDefaults.standard.set(displayName, forKey: lastDisplayNameKey)
        UserDefaults.standard.set(email,       forKey: lastEmailKey)

        // Prompt biometric setup on first interactive sign-in if not yet asked
        let alreadyAsked = UserDefaults.standard.bool(forKey: biometricSetupAskedKey)
        if !alreadyAsked {
            let ctx = LAContext()
            if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                shouldPromptBiometricSetup = true
            }
        }
    }

    /// User agreed to use biometrics — mark as asked.
    func confirmBiometricSetup() {
        UserDefaults.standard.set(true, forKey: biometricSetupAskedKey)
        shouldPromptBiometricSetup = false
    }

    /// User declined biometrics — mark as asked so we never prompt again.
    func skipBiometricSetup() {
        UserDefaults.standard.set(true, forKey: biometricSetupAskedKey)
        shouldPromptBiometricSetup = false
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
