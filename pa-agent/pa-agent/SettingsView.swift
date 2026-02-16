import SwiftUI
import UserNotifications
import AVFoundation
import StoreKit
import Speech
import EventKit
import UniformTypeIdentifiers
#if canImport(Photos)
import Photos
#endif
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_EMBEDDING_MODEL") private var storedEmbeddingModel: String = "text-embedding-3-small"
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://admin-mev0a1yu-eastus2.openai.azure.com/openai/deployments/gpt-5.2/chat/completions?api-version=2024-12-01-preview"
    @AppStorage("OPENAI_AZURE_EMBEDDING_ENDPOINT") private var azureEmbeddingEndpoint: String = "https://admin-mev0a1yu-eastus2.cognitiveservices.azure.com"
    @AppStorage("AGENT_NAME") private var storedAgentName: String = "Nexa"
    @AppStorage("USER_NAME") private var storedUserName: String = ""
    @AppStorage("AGENT_ICON") private var agentIcon: String = "brain.head.profile"
    @AppStorage("AGENT_ICON_COLOR") private var agentIconColor: String = "purple"
    @AppStorage("USER_ICON") private var userIcon: String = "person.circle.fill"
    @AppStorage("AGENT_VOICE_ENABLED") private var agentVoiceEnabled: Bool = true
    @AppStorage("AGENT_VOICE_IDENTIFIER") private var agentVoiceIdentifier: String = ""
    @AppStorage("PERMISSION_SETUP_SHOWN") private var permissionSetupShown: Bool = false
    @AppStorage("PREFERRED_TASK_CALENDAR_ID") private var preferredTaskCalendarId: String = ""
    
    @State private var localKey: String = ""
    @State private var localModel: String = "gpt-5.2"
    @State private var localUseAzure: Bool = false
    @State private var localEndpoint: String = ""
    @State private var localEmbeddingEndpoint: String = ""
    @State private var localAgentName: String = "Nexa"
    @State private var localUserName: String = ""
    @State private var localAgentIcon: String = "brain.head.profile"
    @State private var localAgentIconColor: String = "purple"
    @State private var localUserIcon: String = "person.circle.fill"
    @State private var localAgentVoiceEnabled: Bool = true
    @State private var localAgentVoiceIdentifier: String = ""
    @State private var selectedSettingsTab: SettingsTab = .editable
    
    @State private var connectionStatus: String = "not tested"
    @State private var embeddingConnectionStatus: String = "not tested"
    @State private var savedMessage: String = ""
    @State private var referralStatusText: String = ""
    @State private var chatHistoryStatusText: String = ""
    @State private var permissionStatusText: String = ""
    @State private var notificationsPermissionText: String = "Unknown"
    @State private var speechPermissionText: String = "Unknown"
    @State private var calendarPermissionText: String = "Unknown"
    @State private var remindersPermissionText: String = "Unknown"
    @State private var photosPermissionText: String = "Unknown"
    @State private var taskCalendarChoices: [EKCalendar] = []
    @State private var isEditing: Bool = false
    @State private var previewSynthesizer = AVSpeechSynthesizer()
    @State private var isExportingChatHistory = false
    @State private var isImportingChatHistory = false
    @State private var chatBackupDocument = ChatHistoryBackupDocument(data: Data())
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @ObservedObject var historyManager: ActivityHistoryManager
    private let intentService = IntentService()
    private let eventStore = EKEventStore()

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case editable
        case diagnosticsTools
        case permissions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .editable:
                return "Profile"
            case .diagnosticsTools:
                return "Diagnostics"
            case .permissions:
                return "Permissions"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $selectedSettingsTab) {
                        ForEach(SettingsTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if isEditing && hasUnsavedChanges {
                    Section {
                        Label("You have unsaved changes. Tap Save Settings.", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                switch selectedSettingsTab {
                case .editable:
                    Section {
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

                    Section("Subscription") {
                        if isProductionBuild {
                            Text("To subscribe, iPhone must be signed in to App Store. If prompted for account, sign in first, then tap Subscribe again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Status")
                                Spacer()
                                Text(subscriptionManager.displayStatus)
                                    .foregroundStyle(subscriptionManager.hasActiveSubscription ? .green : .secondary)
                            }

                            if let product = subscriptionManager.primaryProduct {
                                HStack {
                                    Text(product.displayName)
                                    Spacer()
                                    Text(product.displayPrice)
                                        .foregroundStyle(.secondary)
                                }
                            } else if subscriptionManager.isLoadingProducts {
                                HStack {
                                    ProgressView()
                                    Text("Loading subscription...")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Button(subscriptionManager.isPurchasing ? "Processing..." : "Subscribe") {
                                Task { await subscriptionManager.purchasePrimarySubscription() }
                            }
                            .disabled(subscriptionManager.isPurchasing || subscriptionManager.primaryProduct == nil)

                            Button("Restore Purchases") {
                                Task { await subscriptionManager.restorePurchases() }
                            }

                            Button("Open App Store Subscriptions") {
                                guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
                                openURL(url)
                            }

                            if !subscriptionManager.statusMessage.isEmpty {
                                Text(subscriptionManager.statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Debug mode: AI is always enabled and subscription status is not checked.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

                                TextField("Embedding Endpoint URL", text: $localEmbeddingEndpoint)
                                    .textInputAutocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .font(.caption)
                                Text("Format: https://{resource}.cognitiveservices.azure.com")
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

                case .diagnosticsTools:
                    Section("Diagnostics") {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(connectionStatus)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Embeddings")
                            Spacer()
                            Text(embeddingConnectionStatus)
                                .foregroundStyle(.secondary)
                        }
                        Button("Test Connection") {
                            Task {
                                guard isAIFeatureEnabled else {
                                    connectionStatus = "subscription required"
                                    return
                                }
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
                        .disabled(!isAIFeatureEnabled)

                        Button("Test Embedding Connection") {
                            Task {
                                guard isAIFeatureEnabled else {
                                    embeddingConnectionStatus = "subscription required"
                                    return
                                }

                                embeddingConnectionStatus = "testing..."
                                let keyForTest = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                let modelForTest = storedEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                embeddingConnectionStatus = await ChatHistoryStore.shared.testEmbeddingConnection(
                                    apiKey: keyForTest,
                                    model: modelForTest.isEmpty ? nil : modelForTest,
                                    useAzure: localUseAzure,
                                    azureEndpoint: localEmbeddingEndpoint
                                )
                            }
                        }
                        .disabled(!isAIFeatureEnabled)
                    }

                    Section("Tools") {
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

                        NavigationLink("About") {
                            AboutView()
                        }
                        NavigationLink("View Activity History") {
                            ActivityHistoryView(historyManager: historyManager)
                        }
                    }

                    Section("Chat History") {
                        Button {
                            prepareChatHistoryExport()
                        } label: {
                            Label("Backup Chat History", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            isImportingChatHistory = true
                        } label: {
                            Label("Import Chat History", systemImage: "square.and.arrow.down")
                        }

                        if !chatHistoryStatusText.isEmpty {
                            Text(chatHistoryStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                case .permissions:
                    Section("Permissions") {
                        HStack {
                            Text("Notifications")
                            Spacer()
                            Text(notificationsPermissionText)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Speech + Mic")
                            Spacer()
                            Text(speechPermissionText)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Calendar")
                            Spacer()
                            Text(calendarPermissionText)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Reminders")
                            Spacer()
                            Text(remindersPermissionText)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Photos")
                            Spacer()
                            Text(photosPermissionText)
                                .foregroundStyle(.secondary)
                        }

                        Button("Request Notifications") {
                            Task {
                                _ = await requestNotificationPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        Button("Request Speech + Microphone") {
                            Task {
                                _ = await requestSpeechPermission()
                                _ = await requestMicrophonePermission()
                                refreshPermissionStatuses()
                            }
                        }

                        Button("Request Calendar") {
                            Task {
                                await requestCalendarPermission()
                                refreshPermissionStatuses()
                                refreshTaskCalendarChoices()
                            }
                        }

                        Button("Request Reminders") {
                            Task {
                                await requestReminderPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        Button("Request Photos") {
                            Task {
                                _ = await requestPhotoLibraryPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        Button("Open iOS App Settings") {
                            #if canImport(UIKit)
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                            #endif
                        }

                        Button("Reset Permission Setup Prompt") {
                            permissionSetupShown = false
                            permissionStatusText = "Permission setup prompt reset. It will appear next app launch."
                        }

                        if !permissionStatusText.isEmpty {
                            Text(permissionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Task Calendar") {
                        if taskCalendarChoices.isEmpty {
                            Text("No writable calendars available. Grant Calendar access first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Default Task Calendar", selection: $preferredTaskCalendarId) {
                                Text("Default Calendar").tag("")
                                ForEach(taskCalendarChoices, id: \.calendarIdentifier) { calendar in
                                    Text(calendar.title).tag(calendar.calendarIdentifier)
                                }
                            }
                            .pickerStyle(.menu)
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
                localEmbeddingEndpoint = azureEmbeddingEndpoint
                localAgentName = storedAgentName
                localUserName = storedUserName
                localAgentIcon = agentIcon
                localAgentIconColor = agentIconColor
                localUserIcon = userIcon
                localAgentVoiceEnabled = agentVoiceEnabled
                localAgentVoiceIdentifier = agentVoiceIdentifier
                refreshPermissionStatuses()
                refreshTaskCalendarChoices()

                if isProductionBuild {
                    Task {
                        await subscriptionManager.loadProducts()
                        await subscriptionManager.refreshSubscriptionStatus()
                    }
                }
            }
            .fileExporter(
                isPresented: $isExportingChatHistory,
                document: chatBackupDocument,
                contentType: .json,
                defaultFilename: chatHistoryBackupFileName
            ) { result in
                switch result {
                case .success:
                    chatHistoryStatusText = "Backup exported."
                case .failure(let error):
                    chatHistoryStatusText = "Backup failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $isImportingChatHistory,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        chatHistoryStatusText = "Import cancelled."
                        return
                    }

                    do {
                        let accessGranted = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessGranted {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }

                        let data = try Data(contentsOf: url)
                        let importedCount = try ChatHistoryStore.shared.importBackupData(data)
                        chatHistoryStatusText = "Imported \(importedCount) messages."
                    } catch {
                        chatHistoryStatusText = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    chatHistoryStatusText = "Import failed: \(error.localizedDescription)"
                }
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
        let azureChanged = !isProductionBuild && (
            localUseAzure != useAzure ||
            localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) != azureEndpoint ||
            localEmbeddingEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) != azureEmbeddingEndpoint
        )
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
            azureEmbeddingEndpoint = localEmbeddingEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var isAIFeatureEnabled: Bool {
        #if DEBUG
        return true
        #else
        return subscriptionManager.hasActiveSubscription
        #endif
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

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "v\(version).\(build)"
    }

    private var chatHistoryBackupFileName: String {
        let dateText = Date().formatted(.iso8601.year().month().day())
        return "nexa-chat-history-\(dateText)"
    }

    private func prepareChatHistoryExport() {
        do {
            chatBackupDocument = ChatHistoryBackupDocument(data: try ChatHistoryStore.shared.exportBackupData())
            isExportingChatHistory = true
        } catch {
            chatHistoryStatusText = "Backup failed: \(error.localizedDescription)"
        }
    }

    private func refreshPermissionStatuses() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationsPermissionText = self.notificationStatusLabel(settings.authorizationStatus)
            }
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        speechPermissionText = "\(speechStatusLabel(speechStatus)) • Mic \(microphoneStatusLabel(micStatus))"

        calendarPermissionText = calendarStatusLabel(EKEventStore.authorizationStatus(for: .event))
        remindersPermissionText = reminderStatusLabel(EKEventStore.authorizationStatus(for: .reminder))
        photosPermissionText = photoLibraryStatusLabel(currentPhotoLibraryStatus())
    }

    private func currentPhotoLibraryStatus() -> PHAuthorizationStatus {
        #if canImport(Photos)
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        return .notDetermined
        #endif
    }

    private func refreshTaskCalendarChoices() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let canReadCalendars: Bool

        if #available(iOS 17, *) {
            canReadCalendars = status == .fullAccess || status == .writeOnly
        } else {
            canReadCalendars = status == .authorized
        }

        guard canReadCalendars else {
            taskCalendarChoices = []
            preferredTaskCalendarId = ""
            return
        }

        let calendars = eventStore.calendars(for: .event).filter {
            $0.allowsContentModifications && $0.type != .subscription && $0.type != .birthday
        }

        taskCalendarChoices = calendars
        if !preferredTaskCalendarId.isEmpty,
           !calendars.contains(where: { $0.calendarIdentifier == preferredTaskCalendarId }) {
            preferredTaskCalendarId = ""
        }
    }

    private func requestNotificationPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestCalendarPermission() async {
        if #available(iOS 17, *) {
            _ = try? await eventStore.requestFullAccessToEvents()
        } else {
            _ = try? await eventStore.requestAccess(to: .event)
        }
    }

    private func requestReminderPermission() async {
        if #available(iOS 17, *) {
            _ = try? await eventStore.requestFullAccessToReminders()
        } else {
            _ = try? await eventStore.requestAccess(to: .reminder)
        }
    }

    private func requestPhotoLibraryPermission() async -> Bool {
        #if canImport(Photos)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    private func notificationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not Set"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    private func speechStatusLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not Set"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private func microphoneStatusLabel(_ status: AVAudioSession.RecordPermission) -> String {
        switch status {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .undetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private func calendarStatusLabel(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Full Access"
        case .writeOnly: return "Write Only"
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private func reminderStatusLabel(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Full Access"
        case .writeOnly: return "Write Only"
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private func photoLibraryStatusLabel(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .limited: return "Limited"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
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

struct ChatHistoryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
