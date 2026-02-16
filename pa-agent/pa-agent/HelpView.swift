import SwiftUI

struct HelpUseCase: Identifiable {
    let id = UUID()
    let title: String
    let userLine: String
    let agentLine: String
}

struct HelpView: View {
    private let useCases: [HelpUseCase] = [
        HelpUseCase(
            title: "Create a Task",
            userLine: "user: Remind me to send the project update tomorrow at 9 AM.",
            agentLine: "agent: Got it — I created a task for tomorrow at 9:00 AM and set a reminder."
        ),
        HelpUseCase(
            title: "Send a Message",
            userLine: "user: Text Alex that I will join the meeting 10 minutes late.",
            agentLine: "agent: I prepared a message to Alex: ‘I’ll join the meeting 10 minutes late.’ Ready to send."
        ),
        HelpUseCase(
            title: "Make a Call",
            userLine: "user: Call Mom after work.",
            agentLine: "agent: I scheduled a call task for after work and can start the call when you’re ready."
        ),
        HelpUseCase(
            title: "Plan with Priority",
            userLine: "user: Add urgent task to finish tax documents by Friday.",
            agentLine: "agent: Task added with high priority and due Friday. I’ll keep it highlighted until completed."
        ),
        HelpUseCase(
            title: "Quick Daily Check",
            userLine: "user: What should I focus on today?",
            agentLine: "agent: You have 3 open tasks today. Start with ‘Prepare client summary’ (high priority)."
        )
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Swipe to see examples")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TabView {
                ForEach(useCases) { useCase in
                    HelpCarouselCard(useCase: useCase)
                        .padding(.horizontal)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(maxHeight: 360)

            Text("Use natural language. Start with requests like “Remind me…”, “Text…”, or “Call…”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical)
        .navigationTitle("Help")
    }
}

private struct HelpCarouselCard: View {
    let useCase: HelpUseCase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(useCase.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text(useCase.userLine)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(useCase.agentLine)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
