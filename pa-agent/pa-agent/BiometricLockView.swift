import SwiftUI
import LocalAuthentication

// MARK: - BiometricLockView
// Shown on re-launch when a cached Entra account exists.
// Prompts Face ID / Touch ID to restore the session silently.

struct BiometricLockView: View {

    @EnvironmentObject private var authManager: AuthManager
    @State private var isAuthenticating = false

    private var biometryLabel: String {
        switch authManager.biometryType {
        case .faceID:   return "Face ID"
        case .touchID:  return "Touch ID"
        default:        return "Biometrics"
        }
    }

    private var biometryIcon: String {
        switch authManager.biometryType {
        case .faceID:   return "faceid"
        case .touchID:  return "touchid"
        default:        return "lock.shield.fill"
        }
    }

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(.systemBackground), Color.blue.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Lock icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.85), Color.blue.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)
                        .shadow(color: Color.blue.opacity(0.3), radius: 16, x: 0, y: 8)

                    Image(systemName: biometryIcon)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 28)

                Text("Welcome back")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Use \(biometryLabel) to unlock Nexa")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.bottom, 48)

                // Unlock button
                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 10) {
                        if isAuthenticating {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: biometryIcon)
                                .font(.system(size: 18, weight: .semibold))
                        }
                        Text(isAuthenticating ? "Verifying…" : "Unlock with \(biometryLabel)")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isAuthenticating)
                .padding(.horizontal, 28)

                // Error message
                if let error = authManager.authError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 16)
                }

                Spacer()

                // Use a different account
                Button {
                    authManager.cancelBiometricAndSignOut()
                } label: {
                    Text("Use a different account")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            // Small delay ensures the view is fully presented before Face ID prompt fires
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                authenticate()
            }
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            await authManager.biometricSignIn()
            isAuthenticating = false
        }
    }
}

#Preview {
    BiometricLockView()
        .environmentObject(AuthManager())
}
