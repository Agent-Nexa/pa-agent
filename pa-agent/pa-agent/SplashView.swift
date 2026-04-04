import SwiftUI

// MARK: - SplashView
// Shown briefly on launch while AuthManager.silentSignIn() resolves.
// Prevents LoginView from flashing before the biometric / session check completes.

struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
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
                        .shadow(color: Color.blue.opacity(0.3), radius: pulse ? 24 : 12, x: 0, y: 8)
                        .scaleEffect(pulse ? 1.04 : 1.0)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }

                Text("Nexa")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.blue)
                    .scaleEffect(0.9)
            }
        }
        .onAppear { pulse = true }
    }
}

#Preview {
    SplashView()
}
