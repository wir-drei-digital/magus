---
title: Agent Automation
description: Set up your agent to check for work periodically without you prompting it
order: 5
---

# Agent Automation

Automation lets your agent work on its own schedule. Instead of waiting for you to send a message, the agent wakes up at regular intervals, checks whether there is anything to do, and takes action if needed.

## The heartbeat

The **heartbeat** is a recurring trigger that wakes your agent up at a set interval. When the heartbeat fires, the agent runs its heartbeat instructions and decides whether to take any action.

Think of it like a periodic check-in: "Is there anything I should be doing right now?"

## Setting the heartbeat interval

On the agent's page, open the **Automation** section. Enter the **interval in minutes** (minimum 5) to choose how often the heartbeat fires.

Choose an interval that matches how time-sensitive the agent's work is. A log monitoring agent might need every 15 minutes (interval 15); a daily digest agent only needs once per day (interval 1440).

To disable the heartbeat, turn off the **Heartbeat enabled** toggle. The agent will stop running automatically and will only respond when you send a message. There is also a **Paused** toggle that stops the agent entirely.

## Heartbeat instructions

The heartbeat instructions tell the agent what to look for and what to do when the heartbeat fires. Write these as clear, specific guidance. For example:

- "Check the RSS feeds for any articles about [topic]. If there are new ones, summarize the most important ones and send me a message."
- "Look at the error logs. If there are any new critical errors since the last check, create a task and alert me."
- "Review my calendar for tomorrow. If I have back-to-back meetings, draft a heads-up message for my team."

Good heartbeat instructions are specific about the condition ("if there are new critical errors") and the action ("create a task and alert me"). Vague instructions lead to unpredictable behavior.

## Safety limits

Automation includes safety limits to prevent runaway costs or unexpected behavior.

**Max daily runs**: The maximum number of times the heartbeat can actually do work in a single day, configurable in the Automation section. Even if the interval would trigger more often, the agent stops after this many active runs. This protects against edge cases where every heartbeat finds work to do.

On top of that, Magus enforces a per-run token budget and your subscription limits, so an automated run can never spend without bound.

Set the daily-run limit conservatively when you first configure automation, then adjust based on how the agent behaves.

## Run now

The **Run now** button at the top of the agent's page fires the heartbeat immediately, without waiting for the next scheduled interval. Use this to test your heartbeat instructions or to kick off a run on demand.

Triggering manually does not count against the max daily runs limit.

## Viewing automation history

Each wake-up leaves a trace message in the agent's home conversation, and the agent's **Activity** section lists recent runs and tool calls. This helps you tune the interval and instructions over time.
