# Nexa - Personal Agent iOS App

Nexa (formerly PA-Agent) is an intelligent, voice-enabled personal assistant app built with SwiftUI. It leverages OpenAI's Large Language Models (LLMs) to understand natural language intent, manage your schedule, and facilitate communication tasks like calling and messaging.

## Key Features

### 🧠 AI-Powered Intelligence
*   **Natural Language Understanding**: Speak or type freely. The app uses OpenAI (GPT-4o, etc.) or Azure OpenAI to parse intents.
*   **Smart Intent Recognition**: Automatically distinguishes between:
    *   **Tasks**: "Remind me to submit the report on Friday."
    *   **Messages**: "Tell Mom I'll be late."
    *   **Calls**: "Call John about the project."

### ✅ Advanced Task Management
*   **Smart Parsing**: Extracts dates ("tomorrow at 5pm"), priorities ("urgent"), and context tags ("Work", "Personal") automatically from your command.
*   **Calendar Sync**: Automatically adds created tasks to your iOS Calendar.
*   **Smart Notifications**: Schedules local push notifications to remind you when a task is starting.
*   **Task Views**:
    *   **Horizontal Board**: Quick glance at active tasks.
    *   **Detailed List**: Filter tasks by "Today", "Upcoming", or "All".

### 📞 Communication Agent
*   **Hands-Free Messaging**: Drafts SMS messages directly from voice commands.
*   **Assisted Calling**:
    *   Initiates phone calls to contacts.
    *   **Call Scripting**: The agent can generate and read out a "script" or talking points for you before connecting the call, ensuring you're prepared.

### 🗣️ Voice Service
*   **Speech-to-Text**: Dictate your requests using Apple's Speech Framework.
*   **Text-to-Speech (TTS)**: The agent replies audibly, reading out confirmations, scripts, and incoming messages.

### 🎨 Personalization
*   **Custom Agent Identity**: Rename your assistant in Settings (default: "Nexa").
*   **Custom Avatars**: Choose any SF Symbol to represent yourself and the agent in the chat interface.

### ⚙️ Configuration
*   **Bring Your Own Key**: Support for personal OpenAI API keys.
*   **Azure Support**: Full support for Azure OpenAI endpoints for enterprise users.
*   **Model Selection**: Toggle between models (e.g., gpt-4o, gpt-3.5-turbo).

## Requirements
*   iOS 16.0+
*   OpenAI API Key (or Azure OpenAI setup)
*   Permissions:
    *   Microphone & Speech Recognition
    *   Contacts (for finding people to call/message)
    *   Calendar & Reminders (for scheduling)
    *   Notifications

## Getting Started
1.  Launch the app.
2.  Open **Settings** (via the header button or menu).
3.  Enter your OpenAI API Key.
4.  (Optional) Customize the Agent Name and Icons.
5.  Start chatting! Try saying: *"Schedule a meeting with the design team for next Tuesday at 2 PM, high priority."*
