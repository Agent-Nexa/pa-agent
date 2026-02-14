import SwiftUI

struct SettingsView: View {
    @AppStorage("OPENAI_API_KEY") private var storedApiKey: String = ""
    @AppStorage("OPENAI_MODEL") private var storedModel: String = "gpt-5.2"
    @AppStorage("OPENAI_USE_AZURE") private var useAzure: Bool = true
    @AppStorage("OPENAI_AZURE_ENDPOINT") private var azureEndpoint: String = "https://admin-mev0a1yu-eastus2.openai.azure.com/openai/deployments/gpt-5.2/chat/completions?api-version=2024-12-01-preview"
    @AppStorage("AGENT_NAME") private var storedAgentName: String = "Nexa"
    
    @State private var localKey: String = ""
    @State private var localModel: String = "gpt-5.2"
    @State private var localUseAzure: Bool = false
    @State private var localEndpoint: String = ""
    
    @State private var connectionStatus: String = "not tested"
    private let intentService = IntentService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent Identity") {
                    TextField("Agent Name", text: $storedAgentName)
                }

                Section("OpenAI API Key") {
                    SecureField("sk-...", text: $localKey)
                        .textInputAutocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save key") {
                        storedApiKey = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                Section("Model") {
                    Picker("Model", selection: $localModel) {
                        Text("gpt-5.2").tag("gpt-5.2")
                        Text("gpt-4o").tag("gpt-4o")
                        Text("gpt-4o-mini").tag("gpt-4o-mini")
                        Text("gpt-3.5-turbo").tag("gpt-3.5-turbo")
                    }
                    .pickerStyle(.segmented)
                    Button("Save model") { storedModel = localModel }
                }
                
                Section("Azure OpenAI") {
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
                    Button("Save Azure Settings") {
                        useAzure = localUseAzure
                        // Ensure we clean whitespace
                        azureEndpoint = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                    }
                    Button("Test Logic") {
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
            }
            .navigationTitle("Settings")
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
            }
        }
    }
}
