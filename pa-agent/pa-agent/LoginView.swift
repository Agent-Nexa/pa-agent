import SwiftUI

// MARK: - LoginView
// Full-screen login gate. Shown whenever AuthManager.isSignedIn == false.

struct LoginView: View {

    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(.systemBackground), Color.purple.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App icon / logo
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.85), Color.purple.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)
                        .shadow(color: Color.purple.opacity(0.35), radius: 16, x: 0, y: 8)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 24)

                // App name
                Text("Nexa")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Your intelligent personal assistant")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.bottom, 48)

                // Sign-in card
                VStack(spacing: 20) {
                    // New-user offer banner
                    HStack(spacing: 10) {
                        Image(systemName: "gift.fill")
                            .foregroundStyle(Color.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New users get 200 free credits")
                                .font(.subheadline.weight(.semibold))
                            Text("One-time welcome offer on first sign-in")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Sign-in button
                    SignInButton {
                        signIn()
                    }
                    .disabled(authManager.isLoading)

                    // Error message
                    if let error = authManager.authError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 28)

                Spacer()

                // Footer
                Text("Your data stays on your device. Sign-in is required to use Nexa.")
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 28)
            }

            // Loading overlay while silent sign-in resolves
            if authManager.isLoading {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                    .tint(.purple)
            }
        }
    }

    // MARK: - Actions

    private func signIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }
        authManager.signIn(presenting: rootVC)
    }
}

// MARK: - Generic Sign-In Button

private struct SignInButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Sign in to continue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                LinearGradient(
                    colors: [Color.purple, Color.purple.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}



#Preview {
    LoginView()
        .environmentObject(AuthManager())
}
