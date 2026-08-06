---
title: Creating an Agent
description: Step-by-step guide to creating your own custom agent
order: 2
---

# Creating an Agent

Custom agents let you build a specialized assistant tailored to a specific task or workflow. Here is how to create one.

## Step 1: Go to Agents

Switch to the **Agents** mode in the left rail. The sidebar lists any agents you have already created.

## Step 2: Click New agent

Click **New agent** at the top of the sidebar. A small dialog asks for a name and optional instructions. Click **Create** and the agent's configuration page opens.

## Step 3: Fill in the profile

On the agent page, the **General** section holds the profile:

- **Name and description**: give your agent a clear name that describes what it does, for example "Code Reviewer", "Research Assistant", or "Support Bot".
- **Image**: upload your own image, or click **Generate** to describe what you want and let Magus create a picture for your agent. This is a great way to give it a unique visual identity without any design work.
- **Icon**: alternatively, a single emoji shown in lists and menus when no image is set.

## Step 4: Write the instructions

The instructions are the most important part of your agent. They are a system prompt that tells the AI:

- What its role is ("You are a senior code reviewer...")
- What tone to use (concise, friendly, formal, etc.)
- What to focus on or avoid
- Any background knowledge it should keep in mind
- How to handle specific situations

Write these as if you were briefing a new team member. Be specific. The more clearly you explain the context, the more reliably the agent will behave the way you want.

A few tips:

- Start with a one-sentence description of the role.
- List any hard rules the agent should always follow.
- Give examples of good responses if the behavior is subtle.
- Keep it focused: an agent that does one thing well beats one that tries to do everything.

## Step 5: Set a default chat mode

In the agent's **Tools** section, choose the **Default mode** for conversations that use this agent:

- **Chat**: Standard conversation mode.
- **Search**: The agent searches the web before answering.
- **Reasoning**: The agent takes more time to think through complex problems.
- **Image generation** / **Video generation**: The agent produces images or videos from descriptions.

You can always change the mode on a per-conversation basis. The default is just what the agent starts with.

## Step 6: Save

Each section has its own **Save** button for text fields; toggles apply immediately. Your agent is ready to use.

## Using your agent

Click **Start chat** at the top of the agent's page to open a conversation with it, or mention it in any conversation by typing **@** followed by its handle. The agent's instructions, tools, and integrations are active from the first message.

You can edit your agent at any time by returning to **Agents** and clicking on its name.
