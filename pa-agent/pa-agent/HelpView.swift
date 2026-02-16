import SwiftUI
#if canImport(Charts)
import Charts
#endif

struct HelpUseCase: Identifiable {
    let id = UUID()
    let title: String
    let iconName: String
    let userLine: String
    let agentLine: String
    let showsDiagramSample: Bool

    init(title: String, iconName: String = "lightbulb", userLine: String, agentLine: String, showsDiagramSample: Bool = false) {
        self.title = title
        self.iconName = iconName
        self.userLine = userLine
        self.agentLine = agentLine
        self.showsDiagramSample = showsDiagramSample
    }
}

private struct HelpDiagramRow: Identifiable {
    let id = UUID()
    let status: String
    let category: String
    let count: Int
}

struct HelpView: View {
    private let useCases: [HelpUseCase] = [
        HelpUseCase(
            title: "Create a Task",
            iconName: "checklist",
            userLine: "user: Remind me to send the project update tomorrow at 9 AM.",
            agentLine: "agent: Got it — I created a task for tomorrow at 9:00 AM and set a reminder."
        ),
        HelpUseCase(
            title: "Send a Message",
            iconName: "message.fill",
            userLine: "user: Text Alex that I will join the meeting 10 minutes late.",
            agentLine: "agent: I prepared a message to Alex: ‘I’ll join the meeting 10 minutes late.’ Ready to send."
        ),
        HelpUseCase(
            title: "Make a Call",
            iconName: "phone.fill",
            userLine: "user: Call Mom after work.",
            agentLine: "agent: I scheduled a call task for after work and can start the call when you’re ready."
        ),
        HelpUseCase(
            title: "Plan with Priority",
            iconName: "flag.fill",
            userLine: "user: Add urgent task to finish tax documents by Friday.",
            agentLine: "agent: Task added with high priority and due Friday. I’ll keep it highlighted until completed."
        ),
        HelpUseCase(
            title: "Quick Daily Check",
            iconName: "calendar",
            userLine: "user: What should I focus on today?",
            agentLine: "agent: You have 3 open tasks today. Start with ‘Prepare client summary’ (high priority)."
        ),
        HelpUseCase(
            title: "Task Status Diagram",
            iconName: "chart.bar.xaxis",
            userLine: "user: Show my task status diagram for today.",
            agentLine: "agent: Here’s a chart of Completed / Overdue / Upcoming tasks, with Work vs Personal breakdown in each status.",
            showsDiagramSample: true
        ),
        HelpUseCase(
            title: "Work vs Personal Progress",
            iconName: "person.2.fill",
            userLine: "user: Summarize my work and personal task progress with a chart.",
            agentLine: "agent: I generated a status chart and highlighted how many Work and Personal tasks are completed, overdue, and upcoming."
        )
    ]

    var body: some View {
        VStack(spacing: 10) {
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
            .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 420)

            Text("Use natural language. Try “Remind me…”, “Text…”, “Call…”, or “Show my task status diagram”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpCarouselCard: View {
    let useCase: HelpUseCase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: useCase.iconName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(useCase.title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(useCase.userLine)
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(useCase.agentLine)
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if useCase.showsDiagramSample {
                    HelpDiagramSampleView()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HelpDiagramSampleView: View {
    private let rows: [HelpDiagramRow] = [
        .init(status: "Completed", category: "Work", count: 4),
        .init(status: "Completed", category: "Personal", count: 2),
        .init(status: "Completed", category: "Other", count: 1),
        .init(status: "Overdue", category: "Work", count: 1),
        .init(status: "Overdue", category: "Personal", count: 2),
        .init(status: "Overdue", category: "Other", count: 1),
        .init(status: "Upcoming", category: "Work", count: 3),
        .init(status: "Upcoming", category: "Personal", count: 2),
        .init(status: "Upcoming", category: "Other", count: 1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample Diagram")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            #if canImport(Charts)
            Chart(rows) { row in
                BarMark(
                    x: .value("Status", row.status),
                    y: .value("Count", row.count)
                )
                .foregroundStyle(by: .value("Category", row.category))
            }
            .chartForegroundStyleScale([
                "Work": .purple,
                "Personal": .mint,
                "Other": .gray
            ])
            .frame(height: 150)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            #else
            VStack(alignment: .leading, spacing: 6) {
                Text("Completed: W4 / P2 / O1")
                Text("Overdue: W1 / P2 / O1")
                Text("Upcoming: W3 / P2 / O1")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
