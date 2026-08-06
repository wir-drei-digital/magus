---
title: Telegram
description: Connect a Telegram bot to your agent and chat with it from anywhere
order: 2
---

# Telegram

Connect a Telegram bot to your Magus agent so you can send messages and receive responses directly inside Telegram. This is useful for staying connected to your agents on mobile, sharing access with specific people, or building lightweight bots for your team.

## How It Works

You create a Telegram bot via BotFather (Telegram's official bot creation tool), then connect it to a Magus agent using the bot token. Once connected, anyone who messages your bot will go through an approval flow before they can interact with your agent. You control exactly who has access.

## Step 1: Create a Bot in Telegram

1. Open Telegram and search for **@BotFather**
2. Send the command `/newbot`
3. Follow the prompts: choose a display name and then a username (must end in `bot`, e.g., `myassistant_bot`)
4. BotFather will reply with your **bot token**, a long string like `123456789:ABCdefGhijKlmnopQrsTuvwxyz`

Copy this token and keep it somewhere safe. You'll need it in the next step.

## Step 2: Connect the Bot to Your Agent

1. Go to **Agents** and open the agent you want to connect
2. Go to the **Integrations** section
3. Click **+ Connect new** and select **Telegram**
4. Paste your bot token into the field and complete the wizard

Magus will verify the token and register a webhook with Telegram. Your bot is now live.

## Step 3: The Approval System

When someone sends your bot a message for the first time, Magus does not route it to your agent immediately. Instead, the request lands in a pending list that you review under **Settings → Integrations**.

**Approving a chat:** Click **Approve** next to the pending request. The person can now interact with your agent, and their chat is on the allowed list.

**Denying a chat:** Click **Deny**. No further messages from that chat are processed.

This approval step protects your agent from unexpected access. If your bot username is public, anyone could find it and try to message it. The approval system ensures only the people you've allowed can interact with your agent.

## Managing Allowed Chats

You can view and manage all approved chats under **Settings → Integrations**. The **Allowed chats** section of the Telegram integration lists every approved user or group.

## Removing Chat Access

To revoke someone's access, find their chat in the Allowed chats list and click the remove button next to it. Their future messages will be silently ignored. They won't receive a notification that their access was removed unless you tell them.

## Tips

- **Group chats:** You can add your bot to a Telegram group. When someone in the group messages the bot, the same approval process applies.
- **Bot privacy mode:** By default, Telegram bots in groups only see messages that mention the bot directly. This is controlled by BotFather's privacy settings, not by Magus.
- **Rotating the token:** If your bot token is compromised, generate a new one in BotFather (`/mybots` → select your bot → **API Token** → **Revoke current token**) and update it in the integration settings.
- **Disconnecting:** To remove the Telegram integration entirely, click **Disconnect** on it in the agent's Integrations section. Magus will unregister the webhook and the bot will stop responding.
