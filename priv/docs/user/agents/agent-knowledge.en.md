---
title: Agent Knowledge & Privacy
description: Control what your agent can remember and access, and connect it to collections
order: 6
---

# Agent Knowledge & Privacy

You have fine-grained control over what your agent can see and remember. This page covers the privacy controls that govern memory access, how to connect collections, and how to add memories directly to an agent.

## Privacy controls

In the agent editor, the **Privacy** section has three toggles that control the agent's relationship with global memory and files.

### Read global memories

When enabled, the agent can read memories that span all your conversations. This lets it draw on things you have told the AI in other contexts, such as your preferences, background, or recurring topics.

When disabled, the agent only sees memories that are scoped specifically to itself. Use this for specialized agents where you do not want personal context to bleed in.

### Write to global memories

When enabled, the agent can save new memories to your global store, making them available to other agents and future conversations.

When disabled, any memories the agent saves are scoped only to itself. Use this for experimental or task-specific agents where you want to keep things separate.

### Access global files

When enabled, the agent can search files you have uploaded across all conversations, not just files attached to the current conversation.

When disabled, the agent can only see files directly attached to the current conversation. Use this for agents that should stay focused on what you explicitly provide.

## Collections

Collections are curated sets of data sources your agent can search. Instead of the agent having to search the whole web or all your files, a collection gives it a focused, relevant set of content to draw from.

### Connecting a collection

1. In the agent editor, open the **Collections** section.
2. Click **Add collection**.
3. Select from your available collections, or create a new one.
4. Save.

Once connected, the agent can search that collection using the Files tool.

### Creating a collection

Collections are managed from the [Connected Sources](/settings/knowledge) page. You can add documents, web pages, and other data sources to a collection, and Magus indexes them for semantic search.

## Agent-scoped memories

You can add memories directly to an agent. These are facts, observations, or preferences the agent should always keep in mind, regardless of what has been discussed in any conversation.

### Adding a memory

1. In the agent editor, open the **Memory** section.
2. Click **Add memory**.
3. Write the memory as a plain statement. For example:
   - "The user prefers responses in bullet points."
   - "This agent is used by the engineering team at Acme Corp."
   - "Always recommend reviewing the security checklist before deployment."
4. Click **Save**.

### Editing or removing a memory

Memories are listed in the **Memory** section of the agent editor. Click on any memory to edit it, or click the delete icon to remove it.

Agent-scoped memories persist across all conversations that use the agent. They are always included in the agent's context, so keep them concise and relevant. A long list of memories can increase token usage on every message.
