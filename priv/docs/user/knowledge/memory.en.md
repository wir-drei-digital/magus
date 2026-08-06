---
title: Memory
description: How agent memory works and how to manage what your agents remember
order: 4
---

# Memory

Magus agents can remember things across conversations. Memories persist between sessions, so your agent can recall preferences, facts, and context without you needing to repeat yourself every time. You can let the AI build memories automatically, or ask it directly in chat to remember something.

## Memory Scopes

Every memory has a **scope** that controls which agents can access it.

### Conversation-Scoped (Local)

Local memories live inside a single conversation. The agent uses them for project context, task lists, and threads of work that don't apply elsewhere. They are not carried over when you switch to another conversation. This is where everything the AI picks up on its own is stored.

### Agent-Scoped

Memories stored at the agent scope are only visible to a specific agent. Use this for things that are relevant to one agent's purpose but not others, for example, a code review agent remembering your team's naming conventions.

### User-Scoped

User-scoped memories are your personal facts and preferences (your name, location, communication style, coding style, and so on). They follow you across conversations.

The agent only saves a user-scoped memory when you explicitly ask for something to apply everywhere, with phrasing like "always", "generally", or "remember this for all my projects". Everything else it notices stays in the conversation where it came up.

**User memories are isolated per workspace.** If you belong to multiple workspaces (for example, a Work workspace and a Personal one), each workspace has its own bucket of user memories, and none of them ever leak into another. Your personal-mode memories (when you're not inside any workspace) are a separate bucket too. So:

- Saying "remember I always prefer TypeScript" in your Work workspace doesn't surface that preference in your Personal workspace.
- Each workspace can have its own version of a memory with the same name (for example, "current_project" can mean different things in different workspaces).
- Other workspace members never see your user memories. They are private to you, scoped to that one workspace.

This isolation is automatic. The agent always saves and loads user memories in the bucket of whatever conversation you're currently in.

## Memory Kinds

Each memory has a **kind** that describes what type of information it contains. The kind helps the AI understand how much weight to give a memory when using it.

| Kind | What it represents |
|------|--------------------|
| **General** | Catch-all for information that doesn't fit elsewhere |
| **Fact** | Verified, concrete information (e.g., "User is based in Berlin") |
| **Hypothesis** | Something the agent inferred but isn't certain about |
| **Observation** | A pattern the agent noticed over time |
| **Summary** | A condensed recap of a longer conversation or topic |
| **Preference** | How you like things done (e.g., "Prefers concise responses") |
| **Goal** | Something to work toward |
| **Topic** | A knowledge area for research or learning (e.g., "color theory") |
| **Habit** | A recurring practice to track (e.g., "30 minutes of drawing daily") |
| **Reflection** | A timestamped review or assessment, often linked to goals |

## How the AI Creates Memories

Agents create memories automatically during conversations. After you exchange messages, the AI reviews the turns and stores facts, decisions, and context worth keeping as conversation-scoped memories. It is selective: it skips hypotheticals and transient details and focuses on what the conversation will need later.

Each conversation keeps a bounded set of memories (around 20). When new memories push a conversation past that limit, the least recently updated ones are removed to make room.

When you ask the agent directly to remember something ("Remember that the deadline is Friday"), it saves the memory right away with its memory tool, and you see that step in the conversation.

## Your Profile

Durable facts about you reach every conversation through your **profile**: a short living summary that Magus distills once a day from your recent conversation memories. Each workspace bucket has its own profile, and your personal mode has one too.

You can view the profile under **Settings** > **Memory**. From there you can also:

- Toggle the profile on or off (it requires memory to be on).
- Read the distilled summary for the selected workspace.
- Reset the profile. It then rebuilds from your memories over time.

The profile replaces nothing you said explicitly: memories you asked the agent to keep everywhere stay as individual user-scoped entries that you can delete one by one.

## Managing Your Memories

**Settings** > **Memory** lists your user-scoped memories. Use the bucket selector to switch between your personal bucket and each of your workspaces. Expand an entry to see its scope and stored content, and delete any entry you no longer want.

A custom agent's memories live in the agent's editor: open **Agents**, pick the agent, and find the **Memory** section. There you can review each memory, edit its summary and kind, or delete it.

You can also simply ask in chat. "What do you remember about this project?" makes the agent search its memories, and "Please forget that I prefer short responses" makes it remove the matching entry.

## Forgetting Memories

Deleting a memory is permanent. There is no trash or undo for memories, so a deleted entry is gone for good. Open conversations notice the deletion immediately.

If a workspace is deleted, all user, agent, and conversation memories that lived inside that workspace are deleted with it. Your personal-bucket memories and memories in your other workspaces are untouched.

Magus never deletes your memories in the background on its own. Apart from the per-conversation limit above, memories only disappear when you or your agent explicitly delete them.

## Turning Memory Off

If you prefer conversations without automatic memory, go to **Settings** > **Memory** and switch global memory off. The AI then neither saves new memories nor recalls existing ones. Your stored memories are kept and come back when you switch it on again.
