---
title: Context Window
description: What the context window is, how it fills up, and how to manage it with the Rolling and Auto compact strategies.
order: 1
---

# Context Window

Every AI model can only read a limited amount of text at once. That limit is called the **context window**, measured in **tokens** (a token is roughly four characters, or about three quarters of a word). Each time you send a message, Magus packs the conversation and everything the agent needs into this window and sends it to the model.

When a conversation grows past the window, something has to give: the oldest content is either dropped or summarized so the newest messages still fit. The context indicator next to the composer shows how full the window is and lets you control how that trimming happens.

## The indicator

The small ring next to the send button fills up as the window fills. It turns amber as you approach the limit and red when you are nearly full. Open it to see:

- **Used / total tokens** and the percentage of the window in use.
- A **breakdown** of what is taking up space, largest first. Typical sections:
  - **Messages**: the conversation history.
  - **Tools**: the definitions of the tools the agent can call.
  - **System prompt / Persona**: the agent's base instructions.
  - **Memory, Files, Brain**: context retrieved to answer your message.
  - **Free space**: how much room is left.
- **From cache**: tokens the provider served from its cache, which are cheaper and faster.

## Strategies

The strategy decides what happens when the conversation no longer fits in the window. You can set it per conversation from the indicator, and the highlighted option is the one currently in effect (the app default when you have not chosen one).

### Rolling (default)

Keeps the most recent turns in full and drops the oldest ones as the window fills. Nothing is rewritten, so recent context stays exact. This is the best choice for most chats, where the latest messages matter most.

### Auto compact

When the window gets full, older turns are automatically **summarized** into a short recap instead of being dropped. You keep a thread of the earlier discussion at the cost of some detail. This suits long, evolving conversations where earlier decisions still matter.

## Manual controls

- **Compact now**: summarize the older messages immediately, without waiting for the window to fill. Useful before a long task.
- **Clear**: reset the live context window. Older messages stay in the transcript and on screen, but they are no longer sent to the model. Use this to start fresh in the same conversation.

None of these actions delete your messages from the transcript. They only change what the model sees on the next turn.
