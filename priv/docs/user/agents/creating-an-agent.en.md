---
title: Creating an Agent
description: Step-by-step guide to creating your own custom agent
order: 2
---

# Creating an Agent

Custom agents let you build a specialized assistant tailored to a specific task or workflow. Here is how to create one.

## Step 1: Go to the agents page

Navigate to [/agents](/agents). You will see any agents you have already created, along with a button to create a new one.

## Step 2: Click Create

Click the **Create agent** button (or the **+** icon). A creation form opens.

## Step 3: Choose a name and icon

Give your agent a clear name that describes what it does. For example: "Code Reviewer", "Research Assistant", or "Support Bot".

For the icon, you have a few options:

- **Emoji**: Pick any emoji as a simple icon. Quick and expressive.
- **Custom image**: Upload your own image file.
- **AI-generated image**: Describe what you want and Magus will generate an image for you. This is a great way to give your agent a unique visual identity without any design work.

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

Choose the default mode for conversations that use this agent:

- **Chat**: Standard conversation mode.
- **Search**: The agent searches the web before answering.
- **Reasoning**: The agent takes more time to think through complex problems.
- **Image generation**: The agent produces images from descriptions.

You can always change the mode on a per-conversation basis. The default is just what the agent starts with.

## Step 6: Save

Click **Save** (or **Create**). Your agent is ready to use.

## Using your agent

To use your new agent, start a new conversation and select it from the agent picker, or change the agent on an existing conversation from the conversation settings panel. The agent's instructions, tools, and integrations are active from the moment you switch to it.

You can edit your agent at any time by returning to [/agents](/agents) and clicking on its name.
