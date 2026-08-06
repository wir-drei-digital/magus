---
title: Using Skills
description: Reusable abilities the AI loads on demand, triggered with /commands
order: 3
---

# Using Skills

Skills are packaged instructions (optionally with bundled files) that teach the AI how to do a specific job well, like producing a Word document or following your team's review checklist. The AI loads a skill only when it is needed, so skills do not clutter the context of every conversation.

## Triggering a skill

- **Slash command:** type `/` in the message box and pick a skill, or type its name directly (for example `/word-documents Write a summary of...`). The skill's instructions are applied to that message.
- **Automatically:** the AI sees which skills are available and loads one itself when the task matches its description.

In shared conversations, slash commands resolve against your own skills, so you can use your personal skills anywhere you write.

## Creating and importing skills

In the **Library** you can create a skill (name, description, instructions) or import an existing skill bundle. Good skills have a clear description; that is what the AI uses to decide when to load them.

## Approvals for bundled files

Skills that ship executable content (scripts or tools that run in the sandbox) ask for your approval in the conversation before they run. Approval is bound to the exact skill content: if the skill's files change, you are asked again. You can also trust a skill so it stops asking.
