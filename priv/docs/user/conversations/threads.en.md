---
title: Threads
description: Branch off from any message to explore tangents without losing context
order: 6
---

# Threads

Branch off from any message to explore a tangent without losing context or derailing the main conversation. Threads inherit the parent conversation's context up to the branch point, then run independently with their own agent.

## How it works

A thread is a sub-conversation that starts from a specific message. It gets the full context of the parent conversation up to that message, but anything said in the thread stays in the thread; the main conversation is not affected.

Each thread runs its own agent process. This means:
- The thread can go in a completely different direction than the main conversation
- You can change the model for the thread independently
- Tool calls and responses in the thread don't appear in the main conversation
- The parent agent has no awareness of what happens in the thread

## Starting a thread

### From a message

Hover over any message in a conversation and click the thread icon (arrow). This creates a new thread branching from that message.

If a thread already exists for that message, clicking the icon opens the existing thread instead of creating a new one.

### Agent-created threads

You can ask the agent to start a thread. For example:

> "Start a thread to explore the Docker configuration in detail"

The agent will:
1. Create the thread branching from the relevant message
2. Post an announcement in the main conversation with a link to the thread
3. Send the first message in the thread to kick off the discussion

The announcement appears as a card you can click to open the thread.

## Thread panel

### Desktop

Threads open in a side panel next to the main conversation. You can see both at the same time. The panel includes:

- **Header** with thread title and parent conversation name
- **Branch reference** showing which message the thread branched from
- **Messages** rendered the same as the main conversation (markdown, tool calls, etc.)
- **Chat input** for sending messages in the thread

Close the panel with the X button. The thread persists, and you can reopen it anytime.

### Mobile

On mobile, the thread takes over the full screen with a back button to return to the parent conversation.

## Finding threads

### On messages

Messages that have threads show a reply count indicator below them (e.g., "3 replies"). Click it to open the thread.

### In the sidebar

Threads appear nested under their parent conversation in the sidebar. Click a thread to navigate to the parent conversation and open the thread panel. Threads are ordered by creation date and are not draggable.

## Thread behavior

### Context inheritance

The thread's agent receives all messages from the parent conversation up to the branch point. Messages sent after the branch point in the main conversation are not included in the thread's context.

Parent messages are read fresh each time: if you edit or disable a message in the parent, the thread reflects that change.

### Settings

Threads inherit their parent's settings at creation:
- Model selection (chat, image, video)
- Chat mode
- System prompt
- Custom agent
- Sampling settings

You can change these independently after the thread is created.

### Multiplayer

In multiplayer conversations, threads inherit the parent's members and visibility. All participants can open and contribute to the same thread, or have different threads open simultaneously. Thread panel state is per-user.

### Limits

- **One level only**: you cannot create a thread within a thread
- **One thread per message**: each message can have at most one thread branching from it

### Deletion

Deleting a parent conversation automatically deletes all its threads. Threads cannot be moved to a different parent.
