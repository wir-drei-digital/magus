---
title: Memory
description: How agent memory works and how to manage what your agents remember
order: 3
---

# Memory

Magus agents can remember things across conversations. Memories persist between sessions, so your agent can recall preferences, facts, and context without you needing to repeat yourself every time. You can let the AI build memories automatically, or add them yourself through agent settings.

## Memory Scopes

Every memory has a **scope** that controls which agents can access it.

### Conversation-Scoped (Local)

Local memories live inside a single conversation. The agent uses them for project context, task lists, and threads of work that don't apply elsewhere. They disappear from view when you switch to another conversation.

### Agent-Scoped

Memories stored at the agent scope are only visible to a specific agent. Use this for things that are relevant to one agent's purpose but not others — for example, a code review agent remembering your team's naming conventions.

### User-Scoped

User-scoped memories are your personal facts and preferences (your name, location, communication style, coding style, and so on). They follow you across conversations.

**User memories are isolated per workspace.** If you belong to multiple workspaces (for example, a Work workspace and a Personal one), each workspace has its own bucket of user memories — none of them ever leak into another. Your personal-mode memories (when you're not inside any workspace) are a separate bucket too. So:

- Saying "remember I prefer TypeScript" in your Work workspace doesn't surface that preference in your Personal workspace.
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
| **Goal** | Something to work toward, with optional progress tracking and deadlines |
| **Topic** | A knowledge area for research or learning (e.g., "color theory") |
| **Habit** | A recurring practice to track (e.g., "30 minutes of drawing daily") |
| **Reflection** | A timestamped review or assessment, often linked to goals |

### Structured Data

Some memory kinds can carry additional structured information alongside their free-form content. For example, a goal memory might track a deadline and progress percentage, while a habit memory might track a streak count and last completion date. This structured data is stored as flexible metadata that the AI uses to make more informed decisions during coaching and planning sessions.

## Confidence Scores

Each memory has a confidence score between 0 and 1. A score of 1.0 means the agent is certain about the memory. Lower scores indicate uncertainty, often used for hypotheses or inferences. You can see and adjust confidence scores when editing memories manually.

When the AI retrieves memories to inform a response, it considers confidence scores. Lower-confidence memories are used more cautiously, while high-confidence memories are treated as reliable.

## How the AI Creates Memories

Agents can create memories automatically during conversations. When the AI notices something worth remembering, such as a stated preference, a useful fact, or a pattern, it stores it without interrupting the conversation. You may see a brief notification when this happens.

The AI uses semantic understanding to decide what's worth remembering. It avoids storing every detail and instead focuses on information that is likely to be useful in future conversations.

## Adding Memories Manually

You can add memories directly from an agent's settings page:

1. Go to **Agents** and open the agent you want to configure
2. Navigate to the **Memory** tab
3. Click **Add Memory**
4. Choose a scope (Agent, User, or Local), a kind, and enter the content
5. Optionally set a confidence score
6. Save

User-scoped memories created from a workspace conversation belong to that workspace's bucket. Memories created from personal-mode conversations belong to your personal bucket.

Manually added memories are treated just like agent-created ones. They show up in search and can be retrieved during conversations.

## Searching Memories

From an agent's Memory tab, you can search through stored memories using keywords. The search uses semantic similarity, so you don't need to match exact phrases. Results show the memory content, kind, scope, confidence score, and when the memory was created or last updated.

You can also edit or delete any memory directly from the search results.

## Forgetting Memories

To remove a memory, find it in the Memory tab and click **Delete**. You can also ask your agent to forget something during a conversation: "Please forget that I prefer short responses." The agent will use the Forget Memory tool to remove the relevant entry.

If you want to clear all memories for an agent, use the **Clear All** option in the Memory tab. This only removes memories scoped to that agent. User-scoped and conversation-scoped memories are not affected.

If a workspace is deleted, all user, agent, and conversation memories that lived inside that workspace are deleted with it. Your personal-bucket memories and memories in your other workspaces are untouched.
