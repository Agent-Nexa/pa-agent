import SwiftUI
import UserNotifications
import AVFoundation
import StoreKit
import Speech
import EventKit
import CoreLocation
import UniformTypeIdentifiers
#if canImport(Photos)
import Photos
#endif
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var creditManager: CreditManager
    @AppStorage("OPENAI_EMBEDDING_MODEL") private var storedEmbeddingModel: String = "text-embedding-3-small"
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://pa-agent-api-management-service-01.azure-api.net/openai/models/chat/completions?api-version=2024-05-01-preview"
    @AppStorage("OPENAI_AZURE_EMBEDDING_ENDPOINT") private var azureEmbeddingEndpoint: String = "https://pa-agent-api-management-service-01.azure-api.net/openai/models/embeddings?api-version=2024-05-01-preview"
    @AppStorage("AGENT_NAME") private var storedAgentName: String = "Nexa"
    @AppStorage("USER_NAME") private var storedUserName: String = ""
    @AppStorage("AGENT_ICON") private var agentIcon: String = "brain.head.profile"
    @AppStorage("AGENT_ICON_COLOR") private var agentIconColor: String = "purple"
    @AppStorage("USER_ICON") private var userIcon: String = "person.circle.fill"
    @AppStorage("AGENT_VOICE_ENABLED") private var agentVoiceEnabled: Bool = true
    @AppStorage("AGENT_VOICE_IDENTIFIER") private var agentVoiceIdentifier: String = ""
    @AppStorage("PERMISSION_SETUP_SHOWN") private var permissionSetupShown: Bool = false
    @AppStorage("PREFERRED_TASK_CALENDAR_ID") private var preferredTaskCalendarId: String = ""
    @AppStorage(CalendarEventStartDateStore.key) private var calendarEventStartTimestamp: Double = CalendarEventStartDateStore.defaultTimestamp
    
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
    @State private var showBuyCredits = false
    @State private var chatHistoryStatusText: String = ""
    @State private var permissionStatusText: String = ""
    @State private var notificationsPermissionText: String = "Unknown"
    @State private var speechPermissionText: String = "Unknown"
    @State private var calendarPermissionText: String = "Unknown"
    @State private var remindersPermissionText: String = "Unknown"
    @State private var photosPermissionText: String = "Unknown"
    @State private var cameraPermissionText: String = "Unknown"
    @State private var locationPermissionText: String = "Unknown"
    @State private var taskCalendarChoices: [EKCalendar] = []
    @State private var isEditing: Bool = false
    @State private var previewSynthesizer = AVSpeechSynthesizer()
    @State private var isExportingChatHistory = false
    @State private var isImportingChatHistory = false
    @State private var showClearChatHistoryConfirmation = false
    @State private var chatHistoryStorageSizeText: String = "-"
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
                    // ── Account (Entra profile + credits) ──────────────────
                    Section("Account") {
                        HStack(spacing: 14) {
                            // Monogram avatar
                            ZStack {
                                Circle()
                                    .fill(Color.purple.opacity(0.18))
                                    .frame(width: 46, height: 46)
                                Text(authManager.displayName.prefix(1).uppercased())
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.purple)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authManager.displayName.isEmpty ? "Signed In" : authManager.displayName)
                                    .font(.subheadline.weight(.semibold))
                                if !authManager.email.isEmpty {
                                    Text(authManager.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }

                        HStack {
                            Label("Credits Remaining", systemImage: "sparkles")
                            Spacer()
                            Text(creditManager.displayText)
                                .foregroundStyle(creditManager.credits > 50 ? .green
                                                  : creditManager.credits > 10 ? .orange : .red)
                                .font(.subheadline.monospacedDigit())
                        }

                        Button {
                            showBuyCredits = true
                        } label: {
                            Label("Buy Credits", systemImage: "plus.circle.fill")
                        }
                        .sheet(isPresented: $showBuyCredits) {
                            BuyCreditsSheet()
                                .environmentObject(authManager)
                                .environmentObject(creditManager)
                        }

                        Button(role: .destructive) {
                            authManager.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
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
                        if Bundle.main.isTestFlight {
                            Text("TestFlight mode: AI is always enabled with unlimited tokens and subscription status is ignored.")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        } else if isProductionBuild {
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

                    Section("User Identity") {
                        HStack(spacing: 8) {
                            Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                                .foregroundStyle(isEditing ? .green : .secondary)
                            Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if authManager.isSignedIn {
                            Text("Name and avatar are provided by your Microsoft account.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("Your Name", text: $localUserName)
                            Picker("User Icon", selection: $localUserIcon) {
                                ForEach(iconChoices(including: localUserIcon, defaults: userIconOptions), id: \.self) { symbol in
                                    Label(symbol, systemImage: symbol).tag(symbol)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .disabled(!isEditing)

                    Section("Agent Identity") {
                        HStack(spacing: 8) {
                            Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                                .foregroundStyle(isEditing ? .green : .secondary)
                            Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextField("Agent Name", text: $localAgentName)
                        Picker("Agent Icon", selection: $localAgentIcon) {
                            ForEach(iconChoices(including: localAgentIcon, defaults: agentIconOptions), id: \.self) { symbol in
                                Label(symbol, systemImage: symbol).tag(symbol)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Agent Icon Color", selection: $localAgentIconColor) {
                            Text("Purple").tag("purple")
                            Text("Blue").tag("blue")
                            Text("Green").tag("green")
                            Text("Orange").tag("orange")
                            Text("Red").tag("red")
                            Text("Pink").tag("pink")
                        }
                    }
                    .disabled(!isEditing)

                    Section("Agent Voice") {
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

                    if !isProductionBuild {
                        Section("OpenAI") {
                            HStack(spacing: 8) {
                                Image(systemName: isEditing ? "lock.open.fill" : "lock.fill")
                                    .foregroundStyle(isEditing ? .green : .secondary)
                                Text(isEditing ? "Fields are unlocked" : "Fields are locked")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                        }
                        .disabled(!isEditing)
                    }

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
                                    apiKey: "",
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
                                let modelForTest = storedEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                embeddingConnectionStatus = await ChatHistoryStore.shared.testEmbeddingConnection(
                                    apiKey: "",
                                    model: modelForTest.isEmpty ? nil : modelForTest,
                                    useAzure: localUseAzure,
                                    azureEndpoint: localEmbeddingEndpoint
                                )
                            }
                        }
                        .disabled(!isAIFeatureEnabled)
                    }

                    Section("Tools") {
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

                        Text("Storage Used: \(chatHistoryStorageSizeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            showClearChatHistoryConfirmation = true
                        } label: {
                            Label("Clear Chat History", systemImage: "trash")
                        }

                        if !chatHistoryStatusText.isEmpty {
                            Text(chatHistoryStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .permissions:
                    Section("Permissions") {
                        permissionRow(
                            title: "Notifications",
                            description: "Required for reminders and task alerts.",
                            status: notificationsPermissionText
                        ) {
                            Task {
                                _ = await requestNotificationPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        permissionRow(
                            title: "Speech + Mic",
                            description: "Required for voice input and speech recognition.",
                            status: speechPermissionText
                        ) {
                            Task {
                                _ = await requestSpeechPermission()
                                _ = await requestMicrophonePermission()
                                refreshPermissionStatuses()
                            }
                        }

                        permissionRow(
                            title: "Calendar",
                            description: "Required to sync tasks with Calendar events.",
                            status: calendarPermissionText
                        ) {
                            Task {
                                await requestCalendarPermission()
                                refreshPermissionStatuses()
                                refreshTaskCalendarChoices()
                            }
                        }

                        permissionRow(
                            title: "Reminders",
                            description: "Required to read and sync Apple Reminders.",
                            status: remindersPermissionText
                        ) {
                            Task {
                                await requestReminderPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        permissionRow(
                            title: "Photos",
                            description: "Required to select existing images for chat attachments.",
                            status: photosPermissionText
                        ) {
                            Task {
                                _ = await requestPhotoLibraryPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        permissionRow(
                            title: "Camera",
                            description: "Required to take new photos for chat attachments.",
                            status: cameraPermissionText
                        ) {
                            Task {
                                _ = await requestCameraPermission()
                                refreshPermissionStatuses()
                            }
                        }

                        permissionRow(
                            title: "Location",
                            description: "Required to use your current location for weather.",
                            status: locationPermissionText
                        ) {
                            Task {
                                _ = await requestLocationPermission()
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

                        DatePicker(
                            "Calendar Event Start Date",
                            selection: Binding(
                                get: { CalendarEventStartDateStore.normalizedDate(from: calendarEventStartTimestamp) },
                                set: { newValue in
                                    calendarEventStartTimestamp = CalendarEventStartDateStore
                                        .normalizedDate(from: newValue.timeIntervalSince1970)
                                        .timeIntervalSince1970
                                }
                            ),
                            displayedComponents: .date
                        )

                        Text("This date is used to look at calendar events from that date onward. Any event before this date is ignored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                if azureEndpoint.contains("/openai/responses") || azureEndpoint.contains("pa-agent-api-management-service-01.azure-api.net") {
                    azureEndpoint = "https://pa-agent-api-management-service-01.azure-api.net/openai/models/chat/completions?api-version=2024-05-01-preview"
                }

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
                refreshChatHistoryStorageSize()

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
                        refreshChatHistoryStorageSize()
                    } catch {
                        chatHistoryStatusText = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    chatHistoryStatusText = "Import failed: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("Clear all chat history?", isPresented: $showClearChatHistoryConfirmation) {
                Button("Clear Chat History", role: .destructive) {
                    ChatHistoryStore.shared.clearAllHistory()
                    chatHistoryStatusText = "Chat history cleared."
                    refreshChatHistoryStorageSize()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete current and archived chat history backups stored in the app.")
            }
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        status: String,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)

                Button("Change", action: onChange)
                    .buttonStyle(.bordered)
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 2)
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

        return modelChanged || azureChanged || identityChanged || voiceChanged || selectedVoiceChanged
    }

    private func saveAllSettings() {
        if !isProductionBuild {
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
        // TestFlight hack: disable production mode unless you specifically want it enabled
        // return true 
        return !Bundle.main.isTestFlight
        #endif
    }

    private var environmentLabel: String {
        #if DEBUG
        return "Debug"
        #else
        return Bundle.main.isTestFlight ? "TestFlight" : "Production"
        #endif
    }

    private var environmentColor: Color {
        #if DEBUG
        return .green
        #else
        return Bundle.main.isTestFlight ? .blue : .orange
        #endif
    }

    private var isAIFeatureEnabled: Bool {
        #if DEBUG
        return true
        #else
        // TestFlight hack: Bypass active subscription check
        if Bundle.main.isTestFlight { return true }
        return subscriptionManager.hasActiveSubscription
        #endif
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "v\(version).\(build)"
    }

    private func refreshChatHistoryStorageSize() {
        let sizeInBytes = ChatHistoryStore.shared.chatHistoryStorageSizeBytes()
        chatHistoryStorageSizeText = ByteCountFormatter.string(fromByteCount: Int64(sizeInBytes), countStyle: .file)
    }

    private var agentIconOptions: [String] {
        [
            "brain.head.profile",
            "cpu",
            "sparkles",
            "bolt.circle.fill",
            "aqi.medium",
            "waveform.path.ecg",
            "person.crop.circle.badge.questionmark",
            "message.badge.filled.fill"
        ]
    }

    private var userIconOptions: [String] {
        [
            "person.circle.fill",
            "person.fill",
            "person.crop.circle",
            "person.crop.square",
            "person.2.fill",
            "figure.walk.circle",
            "face.smiling",
            "person.text.rectangle"
        ]
    }

    private func iconChoices(including current: String, defaults: [String]) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []

        for symbol in ([current] + defaults) {
            let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                output.append(trimmed)
            }
        }

        return output
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
        cameraPermissionText = cameraStatusLabel(AVCaptureDevice.authorizationStatus(for: .video))
        locationPermissionText = locationStatusLabel(CLLocationManager().authorizationStatus)
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

    private func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func requestLocationPermission() async -> Bool {
        await UserLocationProvider.shared.requestWhenInUseAuthorization()
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

    private func cameraStatusLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private func locationStatusLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When In Use"
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
