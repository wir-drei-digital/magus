---
title: Agent Integrations
description: Connect external services to your agent, from Telegram to Google Calendar
order: 4
---

# Agent Integrations

Integrations connect your agent to external services. Once connected, your agent can send and receive messages through those services, read external data, and react to events happening outside of Magus.

## Available integrations

### Telegram

Connects your agent to a Telegram bot. Users can message the bot in Telegram and the agent responds. Ideal for making your agent available to people who are not Magus users, or for automating replies in a Telegram group.

### Google Calendar

Gives your agent access to your Google Calendar. The agent can read upcoming events, help you schedule, and reference your availability when planning tasks.

### API

Exposes your agent as a REST endpoint. External applications can send messages to the agent and receive responses programmatically. Useful for embedding agent functionality into your own tools or workflows. See the [API integration guide](../integrations/api-integration.en.md) for details.

### RSS

Connects your agent to one or more RSS feeds. The agent can read and search articles from those feeds, making it useful for monitoring news, following blogs, or tracking updates from a website.

### Log Source

Connects your agent to an application log stream. The agent can monitor for errors, surface patterns, and alert you when something needs attention. Especially useful for on-call or incident-response agents.

## Connecting an integration

1. Open your agent's page.
2. Go to the **Integrations** section.
3. Click **+ Connect new**.
4. A setup wizard opens: pick the service and follow its steps. Most require authorizing Magus to access the external service (for example, signing in with Google for Calendar, or providing a bot token for Telegram).
5. Complete the wizard. The integration appears as connected in the list.

Each integration may have additional settings that appear on its card after connecting.

## Integration-specific settings

Each connected integration is shown as a card with its provider name and status. Depending on the service, the card offers:

- **Tools**: individual toggles for the tools this integration gives the agent. Turn off the ones the agent shouldn't use.
- **Configuration fields**: provider-specific settings, editable right on the card.

## Disconnecting an integration

1. Open the agent's page and go to the **Integrations** section.
2. Find the integration you want to remove.
3. Click **Disconnect** and confirm.

Disconnecting removes the agent's access to that service immediately. Your data in the external service is not affected.

## Notes

- Integrations are per-agent. If you want two agents to use the same external service, you connect it to each agent separately.
- Some integrations (like Telegram) also require you to enable the Integrations tool category under **Tools** so the agent can act on incoming events.
