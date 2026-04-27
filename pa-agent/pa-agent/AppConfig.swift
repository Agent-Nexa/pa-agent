//
//  AppConfig.swift
//  pa-agent
//
//  Single source of truth for all UserDefaults / AppStorage keys and their
//  default values.  Use AppConfig.Keys.* everywhere instead of raw strings.
//
//  Usage in SwiftUI:
//      @AppStorage(AppConfig.Keys.agentName) private var agentName = AppConfig.Defaults.agentName
//
//  Usage in non-view code:
//      UserDefaults.standard.string(forKey: AppConfig.Keys.serverURL) ?? AppConfig.Defaults.serverURL
//

import Foundation

enum AppConfig {

    // MARK: - UserDefaults Keys

    enum Keys {

        // ── AI / OpenAI ────────────────────────────────────────────────
        /// APIM subscription key (optional — APIM manages the real Azure OpenAI key)
        static let apiKey                   = "OPENAI_API_KEY"
        /// Chat model name, e.g. "gpt-5.2"
        static let model                    = "OPENAI_MODEL"
        /// Route through Azure APIM (true) or call api.openai.com directly (false)
        static let useAzure                 = "OPENAI_USE_AZURE"
        /// APIM chat completions endpoint URL
        static let azureEndpoint            = "OPENAI_AZURE_ENDPOINT"
        /// Embedding model name
        static let embeddingModel           = "OPENAI_EMBEDDING_MODEL"
        /// APIM embedding endpoint URL (falls back to azureEndpoint if blank)
        static let azureEmbeddingEndpoint   = "OPENAI_AZURE_EMBEDDING_ENDPOINT"

        // ── Backend server ─────────────────────────────────────────────
        /// Base URL for the pa-agent FastAPI backend (Container App)
        static let serverURL                = "PA_AGENT_SERVER_URL"

        // ── Agent persona ──────────────────────────────────────────────
        static let agentName                = "AGENT_NAME"
        static let agentIcon                = "AGENT_ICON"
        static let agentIconColor           = "AGENT_ICON_COLOR"
        static let agentVoiceEnabled        = "AGENT_VOICE_ENABLED"
        static let agentVoiceIdentifier     = "AGENT_VOICE_IDENTIFIER"

        // ── User profile ───────────────────────────────────────────────
        static let userName                 = "USER_NAME"
        static let userIcon                 = "USER_ICON"

        // ── App state ──────────────────────────────────────────────────
        static let permissionSetupShown     = "PERMISSION_SETUP_SHOWN"
        static let preferredTaskCalendarID  = "PREFERRED_TASK_CALENDAR_ID"
        static let lastTipDate              = "lastTipDate"
        static let lastTipIndex             = "lastTipIndex"
        static let lastSeenAppVersion       = "lastSeenAppVersion"
    }

    // MARK: - Default Values

    enum Defaults {
        static let model                    = "gpt-5.2"
        static let embeddingModel           = "text-embedding-3-small"
        static let useAzure                 = true
        static let agentName                = "Nexa"
        static let agentIcon                = "sparkles"
        static let agentIconColor           = "purple"
        static let agentVoiceEnabled        = false
        static let userName                 = ""
        static let serverURL                 = "https://pa-agent-web-frontend.agreeableisland-6e08f0fa.australiaeast.azurecontainerapps.io"
    }
}
