# Nexa – AI Personal Agent

Nexa (formerly PA-Agent) is a SwiftUI personal assistant app that combines local device context (tasks, calendar, reminders, contacts, notifications, and chat history) with AI intent understanding.

## Features

### AI assistant and intent handling
- Natural-language chat (typed or spoken) for tasking, communication, and Q&A.
- OpenAI / Azure OpenAI support with fallback heuristics if AI is unavailable.
- Intent routing for task creation, SMS drafting, email drafting, phone calls, and general answers.
- Streaming AI responses for answer/chat flows.
- Context-aware responses using in-app state snapshots.

### Task management
- Task creation from natural language with auto parsing of title, priority, tag, start/due dates.
- Task statuses: Open, Completed, Canceled, including overdue detection.
- Completion timestamp tracking (`completedAt`) and status-aware date display.
- Task board cards + full task list sheet.
- Filters by date window (All / Today / Upcoming) and by status.
- Advanced sorting (status priority + due date + stable tie-breakers).
- Swipe actions: mark done/undo, cancel, delete.
- Task details sheet with key metadata.
- Task printing/export-style text output from the task list view.

### Smart scheduling and conflict handling
- Date/time extraction and scheduling heuristics.
- Conflict detection against calendar events.
- Suggested alternative time slots.
- Guided conflict-resolution flow (choose suggestion or specify custom time).
- Reschedule date-time parsing support.

### Calendar and reminders integration
- Read/sync tasks with Calendar and Reminders sources.
- Calendar status sync for app tasks.
- Preferred writable calendar selection.
- Access request helpers for calendar/reminders with status-aware UI.

### Notifications
- Local reminder scheduling for tasks.
- Inactivity "Heartbeat" feature that locally schedules engaging check-in reminders after 3 days of disuse, resetting automatically when the user chats or backgrounds the app.
- In-app notification history with unread tracking and badge count updates.
- Notification center UI: mark all read, clear all, delete individual entries.

### Communication agent
- SMS flow with recipient resolution via Contacts.
- Email drafting flow with recipient resolution, completeness checks, and AI polish.
- Phone call flow with contact lookup and optional generated call script.
- Support for immediate actions and scheduled communication tasks.

### Contacts intelligence
- Contact search/disambiguation.
- Missing contact detail collection flows (phone/email).
- Optional contact creation/update support for unresolved recipients.

### Voice and multimodal input
- Speech-to-text input with silence detection.
- Text-to-speech assistant voice responses.
- Voice preview and selectable assistant voice in settings.
- Photo attachments via camera and photo library.

### Weather support
- Weather queries in chat (for example: “weather tomorrow”).
- Location inference rules:
    - If user provides a location, use it.
    - Otherwise use current device location.
- Forecast day parsing (`today`, `tomorrow`, `day after tomorrow`).
- WeatherKit primary provider with automatic fallback provider when WeatherKit auth/capability is unavailable.

### History, analytics, and diagnostics
- Activity history log (tasks/messages/calls/emails) with clear/delete.
- Chat history persistence with session management.
- Chat history backup export/import (JSON).
- Token usage tracking (daily/monthly summaries, request counts, estimated usage).
- Connection diagnostics for chat and embeddings endpoints.

### Permissions and onboarding
- First-run permission setup flow with user-selectable toggles.
- Permissions currently handled:
    - Notifications
    - Speech + microphone
    - Calendar
    - Reminders
    - Photos
    - Camera
    - Location
- Dedicated permissions page in Settings with live status and “Change” actions.

### Settings and personalization
- Agent/user identity customization (names, icons, icon color).
- OpenAI settings (API key, model selection).
- Azure settings (chat endpoint + embedding endpoint).
- Subscription status and purchase/restore flows (production mode).
- Environment/version display and read-only/edit-save workflow.

### Help and About
- In-app help carousel with practical natural-language examples.
- Sample task status diagram in Help.
- About page with feedback email flow.
- Referral/share actions.

## Requirements
- iOS target from project settings.
- OpenAI API key or Azure OpenAI configuration for AI features.
- Relevant iOS permissions depending on enabled features.

## Quick start
1. Launch app and complete permission setup.
2. Open Settings and configure AI provider (OpenAI or Azure).
3. Optional: customize names/icons/voice.
4. Start chatting with commands like:
     - “Remind me to send the report tomorrow at 9 AM.”
     - “Text Alex I’m running 10 minutes late.”
     - “What’s the weather tomorrow?”
