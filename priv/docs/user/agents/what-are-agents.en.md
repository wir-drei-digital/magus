---
title: What Are Agents
description: Understand how agents power your conversations and what custom agents can do
order: 1
---

# What Are Agents

Every conversation in Magus is powered by an agent. The agent is the AI "brain" behind the conversation: it reads your messages, decides how to respond, runs tools when needed, and remembers things across your chats.

## The default agent

When you start a new conversation, it uses the **default agent**. The default agent is a capable, general-purpose assistant with a broad set of tools available. It works well for most everyday tasks: writing, research, coding help, answering questions, and more.

You do not need to think about agents at all if you just want to chat. The default agent handles everything automatically.

## What makes an agent

An agent is defined by a few key things:

- **Instructions**: A system prompt that tells the AI how to behave, what tone to use, and what it should focus on.
- **Tools**: Capabilities the agent can use, such as searching the web, running code, or reading files.
- **Integrations**: Connections to external services, such as Telegram or Google Calendar.
- **Model**: The AI model the agent uses by default (or it can auto-select based on the task).
- **Knowledge**: Data sources and memories the agent can draw on.

## Custom agents

Custom agents let you create specialized assistants tailored for specific purposes. Instead of a general helper, you might create:

- A **code review agent** that knows your conventions and can read your error logs.
- A **writing assistant** with specific style guidelines baked in.
- A **research agent** connected to RSS feeds and web search.
- A **customer support agent** integrated with your Telegram bot.

Custom agents save you from explaining the same context every time. The instructions, tools, and integrations are always there, ready to go.

## Where to find agents

Visit [your agents page](/agents) to see all the agents you have created, browse examples, and create new ones. From there you can also set which agent a conversation uses.

## Assigning an agent to a conversation

When creating a new conversation, or from the conversation settings panel, you can select which agent to use. The conversation will use that agent's instructions, tools, and integrations for every message.

## Mentioning agents with @

You can bring a custom agent into any conversation by typing **@handle** in your message, where "handle" is the agent's unique handle. For example, if you have an agent with the handle `researcher`, typing `@researcher find recent papers on BEAM concurrency` will route that message directly to the researcher agent.

How it works:

- The mentioned agent receives the message in its own home conversation, processes it with its own instructions and model, and sends the response back to your current conversation.
- The main conversation agent does not reply to the message. Only the mentioned agent responds.
- You can mention multiple agents in one message. Each one will receive the message independently.
- If you mention an agent while already in that agent's home conversation, the agent simply handles the message normally (no separate dispatch needed).
