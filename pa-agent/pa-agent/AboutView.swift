import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AboutView: View {
    @State private var showFeedbackSheet = false
    @State private var feedbackText: String = ""
    @State private var referralStatusText: String = ""

    var body: some View {
        List {
            Section("About Nexa") {
                Text("Nexa is an AI-powered personal assistant that helps you manage tasks, reminders, communication actions, and daily productivity workflows.")
                    .font(.body)
                Text("It combines local context (tasks, history, and notifications) with AI reasoning so requests are handled with awareness and follow-through.")
                    .font(.body)
            }

            Section("Author") {
                LabeledContent("Name", value: "ZHEN YUAN")
            }

            Section("Feedback") {
                Button {
                    showFeedbackSheet = true
                } label: {
                    Label("Leave Feedback", systemImage: "bubble.left.and.text.bubble.right")
                }
            }

            Section("Refer a Friend") {
                Menu {
                    ShareLink(item: referralMessage) {
                        Label("Share Invite", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        copyReferralText()
                    } label: {
                        Label("Copy Invite Text", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("Refer a Friend", systemImage: "person.2.badge.plus")
                }

                if !referralStatusText.isEmpty {
                    Text(referralStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
        .sheet(isPresented: $showFeedbackSheet) {
            NavigationStack {
                Form {
                    Section("Your Feedback") {
                        TextEditor(text: $feedbackText)
                            .frame(minHeight: 180)
                    }

                    Section {
                        if feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Write feedback to enable email.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let mailURL = feedbackMailtoURL {
                            Link(destination: mailURL) {
                                Label("Send Feedback Email", systemImage: "envelope")
                            }
                        } else {
                            Text("Unable to compose feedback email.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Leave Feedback")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showFeedbackSheet = false
                        }
                    }
                }
            }
        }
    }

    private var feedbackMailtoURL: URL? {
        let subject = "Nexa Feedback"
        let body = "Nexa Feedback:\n\n\(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines))"

        guard let subjectEscaped = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let bodyEscaped = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        let raw = "mailto:ad.z.yuan@gmail.com?subject=\(subjectEscaped)&body=\(bodyEscaped)"
        return URL(string: raw)
    }

    private var referralMessage: String {
        "I’m using Nexa to manage tasks and reminders with AI assistance. Give it a try!\n\nDownload: https://apps.apple.com/us/search?term=Nexa"
    }

    private func copyReferralText() {
        #if canImport(UIKit)
        UIPasteboard.general.string = referralMessage
        referralStatusText = "Invite text copied"
        #else
        referralStatusText = "Copy is not available on this platform"
        #endif
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
