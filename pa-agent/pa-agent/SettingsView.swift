import SwiftUI
import UserNotifications
import AVFoundation

struct SettingsView: View {
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://admin-mev0a1yu-eastus2.openai.azure.com/openai/deployments/gpt-5.2/chat/completions?api-version=2024-12-01-preview"
    @AppStorage("AGENT_NAME") private var storedAgentName: String = "Nexa"
    @AppStorage("USER_NAME") private var storedUserName: String = ""
    @AppStorage("AGENT_ICON") private var agentIcon: String = "brain.head.profile"
    @AppStorage("AGENT_ICON_COLOR") private var agentIconColor: String = "purple"
    @AppStorage("USER_ICON") private var userIcon: String = "person.circle.fill"
    @AppStorage("AGENT_VOICE_ENABLED") private var agentVoiceEnabled: Bool = true
    @AppStorage("AGENT_VOICE_IDENTIFIER") private var agentVoiceIdentifier: String = ""
    
    @State private var localKey: String = ""
    @State private var localModel: String = "gpt-5.2"
    @State private var localUseAzure: Bool = false
    @State private var localEndpoint: String = ""
    @State private var localAgentName: String = "Nexa"
    @State private var localUserName: String = ""
    @State private var localAgentIcon: String = "brain.head.profile"
    @State private var localAgentIconColor: String = "purple"
    @State private var localUserIcon: String = "person.circle.fill"
    @State private var localAgentVoiceEnabled: Bool = true
    @State private var localAgentVoiceIdentifier: String = ""
    
    @State private var connectionStatus: String = "not tested"
    @State private var savedMessage: String = ""
    @State private var isEditing: Bool = false
    @State private var previewSynthesizer = AVSpeechSynthesizer()
    @ObservedObject var historyManager: ActivityHistoryManager
    private let intentService = IntentService()

    var body: some View {
        NavigationStack {
            Form {
                if isEditing && hasUnsavedChanges {
                    Section {
                        Label("You have unsaved changes. Tap Save Settings.", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Editable Settings") {
                    HStack(spacing: 8) {
                        Text("Environment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(environmentLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(environmentColor.opacity(0.16))
                            .foregroundStyle(environmentColor)
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 8) {
                        Text("Version")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appVersionLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(isEditing ? "Edit settings below, then tap Save." : "Settings are read-only. Tap Edit to make changes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Identity") {
                    HStack(spacing: 8) {
                        Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                            .foregroundStyle(isEditing ? .green : .secondary)
                        Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Your Name", text: $localUserName)
                    TextField("Agent Name", text: $localAgentName)
                    HStack {
                        TextField("Agent Icon (SF Symbol)", text: $localAgentIcon)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Image(systemName: localAgentIcon)
                            .foregroundStyle(agentColor)
                    }
                    Picker("Agent Icon Color", selection: $localAgentIconColor) {
                        Text("Purple").tag("purple")
                        Text("Blue").tag("blue")
                        Text("Green").tag("green")
                        Text("Orange").tag("orange")
                        Text("Red").tag("red")
                        Text("Pink").tag("pink")
                    }
                    HStack {
                        TextField("User Icon (SF Symbol)", text: $localUserIcon)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Image(systemName: localUserIcon)
                            .foregroundStyle(.blue)
                    }
                }
                .disabled(!isEditing)

                if !isProductionBuild {
                    Section("OpenAI") {
                        HStack(spacing: 8) {
                            Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                                .foregroundStyle(isEditing ? .green : .secondary)
                            Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SecureField("sk-...", text: $localKey)
                            .textInputAutocapitalization(.none)
                            .disableAutocorrection(true)
                        Picker("Model", selection: $localModel) {
                            Text("gpt-5.2").tag("gpt-5.2")
                            Text("gpt-4o").tag("gpt-4o")
                            Text("gpt-4o-mini").tag("gpt-4o-mini")
                            Text("gpt-3.5-turbo").tag("gpt-3.5-turbo")
                        }
                        .pickerStyle(.segmented)
                    }
                    .disabled(!isEditing)
                    
                    Section("Azure") {
                        HStack(spacing: 8) {
                            Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                                .foregroundStyle(isEditing ? .green : .secondary)
                            Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Use Azure", isOn: $localUseAzure)
                        if localUseAzure {
                            TextField("Endpoint URL", text: $localEndpoint)
                                .textInputAutocapitalization(.none)
                                .disableAutocorrection(true)
                                .font(.caption)
                            Text("Format: https://{resource}.openai.azure.com/openai/deployments/{deployment}/chat/completions?api-version=...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!isEditing)
                }

                Section("Voice") {
                    HStack(spacing: 8) {
                        Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                            .foregroundStyle(isEditing ? .green : .secondary)
                        Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Allow Agent Voice", isOn: $localAgentVoiceEnabled)

                    Text(selectedVoiceLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Voice", selection: $localAgentVoiceIdentifier) {
                        Text("System Default").tag("")
                        ForEach(voiceOptions) { option in
                            Text(voiceDisplayName(option))
                                .tag(option.identifier)
                        }
                    }
                    .disabled(!localAgentVoiceEnabled)

                    Button("Preview Voice") {
                        previewVoice()
                    }
                    .disabled(!localAgentVoiceEnabled)
                }
                .disabled(!isEditing)

                Section("Tools") {
                    NavigationLink("View Activity History") {
                        ActivityHistoryView(historyManager: historyManager)
                    }
                }

                Section("Diagnostics") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                    }
                    Button("Test Connection") {
                        Task {
                            connectionStatus = "testing..."
                            // Use localModel (what is currently selected) instead of storedModel (what was last saved)
                            // so the user can test before saving.
                            connectionStatus = await intentService.testConnection(
                                apiKey: localKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                model: localModel,
                                useAzure: localUseAzure,
                                azureEndpoint: localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                    }
                }
                
                Section("Notifications Tools") {
                    Button("Request Permissions") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                            print("Permission granted: \(granted)")
                        }
                    }
                    Button("Test Notification (5s)") {
                        let content = UNMutableNotificationContent()
                        content.title = "Test Notification"
                        content.body = "This is a test notification from PA-Agent."
                        content.sound = .default
                        
                        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                        
                        UNUserNotificationCenter.current().add(request) { error in
                            if let error = error {
                                print("Error scheduling test notification: \(error)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Save" : "Edit") {
                        if isEditing {
                            if hasUnsavedChanges {
                                saveAllSettings()
                            } else {
                                savedMessage = "No changes"
                            }
                            isEditing = false
                        } else {
                            savedMessage = ""
                            isEditing = true
                        }
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    if !savedMessage.isEmpty {
                        Text(savedMessage)
                            .font(.caption)
                            .foregroundStyle(savedMessage == "Saved" ? .green : .secondary)
                            .fixedSize()
                    }
                }
            }
            .onChange(of: hasUnsavedChanges) { _, changed in
                if changed && isEditing {
                    savedMessage = ""
                }
            }
            .onAppear {
                // Auto-fix bad cached endpoints
                if azureEndpoint.contains("/openai/responses") || azureEndpoint == "https://admin-mev0a1yu-eastus2.openai.azure.com/" {
                    azureEndpoint = "https://admin-mev0a1yu-eastus2.openai.azure.com/openai/deployments/gpt-5.2/chat/completions?api-version=2024-12-01-preview"
                }
                
                // Load API Key from Environment Variable (if available) to ensure up-to-date scheme settings
                if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
                    storedApiKey = envKey
                }

                localKey = storedApiKey
                localModel = storedModel
                localUseAzure = useAzure
                localEndpoint = azureEndpoint
                localAgentName = storedAgentName
                localUserName = storedUserName
                localAgentIcon = agentIcon
                localAgentIconColor = agentIconColor
                localUserIcon = userIcon
                localAgentVoiceEnabled = agentVoiceEnabled
                localAgentVoiceIdentifier = agentVoiceIdentifier
            }
        }
    }

    private var agentColor: Color {
        switch localAgentIconColor {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        default: return .purple
        }
    }

    private var hasUnsavedChanges: Bool {
        let keyChanged = !isProductionBuild && (localKey.trimmingCharacters(in: .whitespacesAndNewlines) != storedApiKey)
        let modelChanged = !isProductionBuild && (localModel != storedModel)
        let azureChanged = !isProductionBuild && (localUseAzure != useAzure || localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) != azureEndpoint)
        let identityChanged =
            localAgentName.trimmingCharacters(in: .whitespacesAndNewlines) != storedAgentName ||
            localUserName.trimmingCharacters(in: .whitespacesAndNewlines) != storedUserName ||
            localAgentIcon.trimmingCharacters(in: .whitespacesAndNewlines) != agentIcon ||
            localAgentIconColor != agentIconColor ||
            localUserIcon.trimmingCharacters(in: .whitespacesAndNewlines) != userIcon
        let voiceChanged = localAgentVoiceEnabled != agentVoiceEnabled
        let selectedVoiceChanged = localAgentVoiceIdentifier != agentVoiceIdentifier

        return keyChanged || modelChanged || azureChanged || identityChanged || voiceChanged || selectedVoiceChanged
    }

    private func saveAllSettings() {
        if !isProductionBuild {
            storedApiKey = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
            storedModel = localModel
            useAzure = localUseAzure
            azureEndpoint = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        storedAgentName = localAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        storedUserName = localUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        agentIcon = localAgentIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        agentIconColor = localAgentIconColor
        userIcon = localUserIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        agentVoiceEnabled = localAgentVoiceEnabled
        agentVoiceIdentifier = localAgentVoiceIdentifier

        savedMessage = "Saved"
    }

    private var isProductionBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    private var environmentLabel: String {
        isProductionBuild ? "Production" : "Debug"
    }

    private var environmentColor: Color {
        isProductionBuild ? .orange : .green
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "v\(version) (\(build))"
    }

    private func previewVoice() {
        let utterance = AVSpeechUtterance(string: "Hello, I am your AI assistant voice preview.")
        if !localAgentVoiceIdentifier.isEmpty,
           let selectedVoice = AVSpeechSynthesisVoice(identifier: localAgentVoiceIdentifier) {
            utterance.voice = selectedVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        previewSynthesizer.stopSpeaking(at: .immediate)
        previewSynthesizer.speak(utterance)
    }

    private var voiceOptions: [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { isLikelyHumanVoice($0) }
            .map {
                VoiceOption(
                    identifier: $0.identifier,
                    name: $0.name,
                    genderLabel: genderLabel($0.gender)
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func isLikelyHumanVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let gender = genderLabel(voice.gender)
        guard gender == "Male" || gender == "Female" else { return false }

        let lowerName = voice.name.lowercased()
        let noveltyKeywords = [
            "novelty", "bad news", "good news", "cellos", "bells", "boing", "bubbles", "trinoids", "zarvox", "whisper"
        ]
        return !noveltyKeywords.contains { lowerName.contains($0) }
    }

    private var selectedVoiceName: String {
        if localAgentVoiceIdentifier.isEmpty {
            return "System Default"
        }
        if let voice = AVSpeechSynthesisVoice(identifier: localAgentVoiceIdentifier) {
            return voice.name
        }
        return "Unavailable"
    }

    private var selectedVoiceGender: String {
        if localAgentVoiceIdentifier.isEmpty {
            return ""
        }
        guard let voice = AVSpeechSynthesisVoice(identifier: localAgentVoiceIdentifier) else {
            return ""
        }
        let label = genderLabel(voice.gender)
        return (label == "Male" || label == "Female") ? label : ""
    }

    private var selectedVoiceLine: String {
        if selectedVoiceGender.isEmpty {
            return "Selected: \(selectedVoiceName)"
        }
        return "Selected: \(selectedVoiceName) • \(selectedVoiceGender)"
    }

    private func genderLabel(_ gender: AVSpeechSynthesisVoiceGender) -> String {
        switch gender {
        case .male: return "Male"
        case .female: return "Female"
        default: return "Unspecified"
        }
    }

    private func voiceDisplayName(_ option: VoiceOption) -> String {
        if option.genderLabel == "Male" || option.genderLabel == "Female" {
            return "\(option.name) (\(option.genderLabel))"
        }
        return option.name
    }

    private struct VoiceOption: Identifiable {
        var id: String { identifier }
        let identifier: String
        let name: String
        let genderLabel: String
    }
}
