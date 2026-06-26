---
title: Google Calendar
description: Connect Google Calendar so your agent can manage your schedule
order: 3
---

# Google Calendar

> **Note:** Google verification is still pending. If you need access to Google Calendar integration in the meantime, contact [support@magus.digital](mailto:support@magus.digital). If you're interested in other integrations, reach out to us as well.

Connect your Google Calendar to a Magus agent so it can read your schedule, create events, and keep your calendar up to date. Once connected, you can ask your agent things like "What's on my calendar today?" or "Schedule a meeting with Sarah for Friday at 2pm" in plain language.

## What Your Agent Can Do

Once Google Calendar is connected, your agent can:

- **List events:** See what's coming up on your calendar, filter by date range, or search by title
- **Create events:** Add new events with a title, date, time, location, and optional description
- **Update events:** Change the time, title, description, or other details on existing events
- **Delete events:** Remove events from your calendar

All actions are performed on your behalf using your Google account. The agent will confirm before making changes unless you ask it to proceed directly.

## Connecting Google Calendar

1. Go to **Agents** and open the agent you want to connect
2. Navigate to the **Integrations** tab
3. Click **Add Integration** and select **Google Calendar**
4. Click **Connect with Google**
5. Google will ask you to sign in (if you aren't already) and grant Magus permission to access your calendar
6. After approving, you'll be redirected back to Magus and the integration will be active

Magus requests only the permissions it needs: reading and writing to your calendar. It does not access your Gmail, Drive, or other Google services.

## Timezone Handling

Google Calendar stores events in your account's timezone. Magus reads this timezone setting from your Google account automatically.

If you ask your agent to schedule something at "2pm", it will use your Google account's timezone unless you specify otherwise. You can always clarify: "Schedule a call at 2pm Eastern" or "Set up a reminder for 9am my time."

Your Magus account also has a timezone setting (in **Account Settings**). For best results, make sure both settings match your actual timezone.

## Using It in Conversation

Here are some examples of what you can ask:

**Reading your schedule:**
- "What's on my calendar today?"
- "Do I have anything scheduled this week?"
- "Am I free on Thursday afternoon?"
- "When is my next meeting with the design team?"

**Creating events:**
- "Schedule a dentist appointment for next Tuesday at 10am"
- "Add a team standup every Monday at 9am"
- "Create a reminder to review the report on Friday morning"

**Updating events:**
- "Move my 3pm call to 4pm"
- "Change the location of tomorrow's meeting to Conference Room B"

**Deleting events:**
- "Cancel my Friday lunch"
- "Remove the 2pm meeting from my calendar"

The agent uses natural language to understand your intent, so you don't need to use specific commands or formats.

## Managing the Connection

To view or remove the Google Calendar integration:

1. Open your agent's **Integrations** tab
2. Find the Google Calendar integration
3. Click **Manage** to see the connection status, or **Disconnect** to remove it

Disconnecting removes Magus's access to your Google account. Any events already created on your calendar will remain there; disconnecting does not delete them.

If your Google account credentials expire or need to be refreshed, you'll see a warning in the integration panel and a prompt to reconnect.

## Multiple Calendars

Google accounts often have multiple calendars (personal, work, shared team calendars). By default, your agent works with your primary calendar. If you want it to use a specific calendar, tell it: "Add this to my Work calendar" or "Check my Team Events calendar for availability."
