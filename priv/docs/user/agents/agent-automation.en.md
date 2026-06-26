---
title: Agent Automation
description: Set up your agent to check for work periodically without you prompting it
order: 5
---

# Agent Automation

Automation lets your agent work on its own schedule. Instead of waiting for you to send a message, the agent wakes up at regular intervals, checks whether there is anything to do, and takes action if needed.

## The heartbeat

The **heartbeat** is a recurring trigger that wakes your agent up at a set interval. When the heartbeat fires, the agent runs its triage instructions and decides whether to take any action.

Think of it like a periodic check-in: "Is there anything I should be doing right now?"

## Setting the heartbeat interval

In the agent editor, open the **Automation** section. Use the interval selector to choose how often the heartbeat fires:

- 5 minutes
- 15 minutes
- 30 minutes
- 1 hour
- 4 hours
- 12 hours
- 24 hours

Choose an interval that matches how time-sensitive the agent's work is. A log monitoring agent might need every 15 minutes; a daily digest agent only needs once per day.

To disable the heartbeat, turn it off with the toggle. The agent will stop running automatically and will only respond when you send a message.

## Triage instructions

The triage instructions tell the agent what to look for and what to do when the heartbeat fires. Write these as clear, specific guidance. For example:

- "Check the RSS feeds for any articles about [topic]. If there are new ones, summarize the most important ones and send me a message."
- "Look at the error logs. If there are any new critical errors since the last check, create a task and alert me."
- "Review my calendar for tomorrow. If I have back-to-back meetings, draft a heads-up message for my team."

Good triage instructions are specific about the condition ("if there are new critical errors") and the action ("create a task and alert me"). Vague instructions lead to unpredictable behavior.

## Safety limits

Automation includes safety limits to prevent runaway costs or unexpected behavior.

**Max daily runs**: The maximum number of times the heartbeat can actually do work in a single day. Even if the interval would trigger more often, the agent stops after this many active runs. This protects against edge cases where every heartbeat finds work to do.

**Max messages per run**: The maximum number of messages the agent can send in a single heartbeat run. This keeps individual runs from spiraling into very long conversations.

**Max token spend**: A daily spending cap in tokens. Once the agent has used this many tokens across its automated runs for the day, the heartbeat pauses until the next day.

Set these limits conservatively when you first configure automation, then adjust based on how the agent behaves.

## Trigger now

The **Trigger now** button fires the heartbeat immediately, without waiting for the next scheduled interval. Use this to test your triage instructions or to kick off a run on demand.

Triggering manually does not count against the max daily runs limit.

## Viewing automation history

Each heartbeat run appears in the agent's activity log. You can see when it ran, what the agent did, and how many tokens it used. This helps you tune the interval and triage instructions over time.
