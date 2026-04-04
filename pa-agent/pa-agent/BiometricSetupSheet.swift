import SwiftUI
import LocalAuthentication

// MARK: - BiometricSetupSheet
// Shown once after first interactive sign-in when the device has Face ID / Touch ID.
// Asks the user if they want to unlock the app with biometrics on future launches.

struct BiometricSetupSheet: View {

    @EnvironmentObject private var authManager: AuthManager

    private var biometryLabel: String {
        switch authManager.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    private var biometryIcon: String {
        switch authManager.biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        default:       return "lock.shield.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(Color(.systemFill))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 28)

            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.85), Color.blue.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: Color.blue.opacity(0.3), radius: 12, x: 0, y: 6)

                Image(systemName: biometryIcon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 24)

            Text("Enable \(biometryLabel)?")
                .font(.title2.bold())
                .padding(.bottom, 10)

            Text("Next time you open Nexa, you can unlock instantly using \(biometryLabel) instead of signing in again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 36)

            // Enable button
            Button {
                authManager.confirmBiometricSetup()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: biometryIcon)
                        .font(.system(size: 17, weight: .semibold))
                    Text("Enable \(biometryLabel)")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            // Skip button
            Button {
                authManager.skipBiometricSetup()
            } label: {
                Text("Not now")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

#Preview {
    Text("App")
        .sheet(isPresented: .constant(true)) {
            BiometricSetupSheet()
                .environmentObject(AuthManager())
        }
}
